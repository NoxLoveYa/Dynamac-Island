import AppKit
import Combine
import SwiftUI

extension NSScreen {
    var notchRect: CGRect? {
        // Ne se base pas sur safeAreaInsets qui peut être 0 pendant le slide de Spaces
        guard let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else { return nil }
        // La hauteur du notch est stable (~32-37), on la déduit de left.height ou safeAreaInsets si dispo
        let height: CGFloat = safeAreaInsets.top > 0 ? safeAreaInsets.top : (left.height > 0 ? left.height : 32)
        let x = left.maxX
        let width = right.minX - left.maxX
        guard width > 50 && width < 500 else { return nil }
        return CGRect(x: x, y: frame.maxY - height, width: width, height: height)
    }

    static var notchScreen: NSScreen? {
        // Cache le dernier écran à encoche connu pour survivre aux transitions de Spaces où `screens` est instable
        struct Cache { static var last: NSScreen? }
        if let s = screens.first(where: { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }) {
            Cache.last = s
            return s
        }
        return Cache.last ?? screens.first
    }
}

enum IslandLayout {
    static let panelWidth: CGFloat = 640
    static let expandedWidth: CGFloat = 460
    static let collapsedWidth: CGFloat = 300
    static let expandedContentHeight: CGFloat = 108
    static let collapsedHeight: CGFloat = 32
    static let collapsedWing: CGFloat = 28
    static let spring = Animation.spring(response: 0.26, dampingFraction: 0.86, blendDuration: 0.08)
    static let backgroundSpring = Animation.spring(response: 0.36, dampingFraction: 0.88).delay(0.06)
    static let fastEase = Animation.easeOut(duration: 0.16)
}

@MainActor
final class IslandState: ObservableObject {
    @Published var isExpanded = false
    @Published var isVisible = true
    @Published var notchWidth: CGFloat = 190 {
        didSet {
            if abs(notchWidth - oldValue) > 0.5 {
                // Pendant le slide de Spaces, on met à jour sans animation pour rester collé au notch hardware
                updateCollapsedWidth(for: lastTrack, animated: false)
            }
        }
    }
    @Published var notchHeight: CGFloat = 32
    @Published var dynamicCollapsedWidth: CGFloat = IslandLayout.collapsedWidth
    @Published var dynamicCollapsedOffset: CGFloat = 0

    private var collapseWork: DispatchWorkItem?
    private var cancellable: AnyCancellable?
    private var lastTrack: Track?

    /// Slight margin between the song title's trailing edge and the left edge of the physical notch.
    private let notchSideMargin: CGFloat = 4
    /// Extra width kept minimal so pill/waveform hug the edge.
    private let pillExtraWidth: CGFloat = 4

    // Right wing is fixed: hug edge — [4 notch gap] + 3 transport buttons + EQ + paddings.
    // Buttons are 28pt circles (TransportButton) with 3pt inter-spacing.
    // OuterHStack spacing is 4, so gap→buttons =4 and buttons→EQ =4.
    // This fixed right side drives the *minimum* collapsed width; the song title on the
    // left drives the *maximum* width via `notchWidth`.
    private var collapsedRightFixed: CGFloat {
        let rightPadding: CGFloat = 8
        let spacingToNotch: CGFloat = 4 // outerHStack 4 between gap and buttonsHStack
        let buttonWidth: CGFloat = 28
        let interButtonSpacing: CGFloat = 3
        let spacingButtonsToEQ: CGFloat = 4 // outerHStack 4 between buttonsHStack and EQ
        let eqWidth: CGFloat = 15
        let buttonCount: CGFloat = 3
        return rightPadding + spacingToNotch + buttonCount * buttonWidth + (buttonCount - 1) * interButtonSpacing + spacingButtonsToEQ + eqWidth
    }

    private var collapsedLeftFixed: CGFloat {
        8 + 19 + 4 // left padding + artwork + spacing (HStack 4) — hug edge
    }

    // Compact pill is intentionally taller than the raw notch so it can hug
    // the top edge and still feel vertically centered with the text. Takes 6pt
    // more vertical space (3pt top / 3pt bottom) than the hardware cutout.
    var compactHeight: CGFloat { notchHeight + 6 }
    var compactYOffset: CGFloat { -2 } // nudge up to optically center text vs pill

    var islandSize: CGSize {
        // Expanded view removed — only compact pill remains
        CGSize(width: dynamicCollapsedWidth, height: compactHeight)
    }

    /// Maximum width that the title `Text` is allowed to occupy on the left wing
    /// so its trailing edge stops `notchSideMargin` before the notch's left edge.
    var maxLeftTextWidth: CGFloat {
        let leftFixed = collapsedLeftFixed
        let rightFixed = collapsedRightFixed
        // pillExtraWidth is distributed as extra outside the content, so subtract it
        return max(0, dynamicCollapsedWidth - notchWidth - leftFixed - rightFixed - notchSideMargin - pillExtraWidth)
    }

    private var maxCollapsedWidth: CGFloat {
        let panel = IslandLayout.panelWidth
        let panelHalf = panel / 2
        let maxLeftWing = max(0, panelHalf - notchWidth / 2 - 12)
        let rightFixed = collapsedRightFixed
        let maxByPanel = maxLeftWing + notchWidth + rightFixed + pillExtraWidth
        let screenWidth = NSScreen.notchScreen?.frame.width ?? NSScreen.main?.frame.width ?? 1512
        let rightIconsReserve: CGFloat = 180
        let rightEdge = screenWidth - rightIconsReserve
        let maxByScreen = (rightEdge - 12) - 12
        // Compact pill should never be way wider than expanded — cap to expandedWidth
        return min(maxByPanel, min(min(maxByScreen, panel - 16), IslandLayout.expandedWidth))
    }

    private func updateCollapsedWidth(for track: Track?, animated: Bool = true) {
        let leftFixed = collapsedLeftFixed
        let rightFixed = collapsedRightFixed
        let targetWidth: CGFloat
        let targetOffset: CGFloat
        if let track, track.hasContent {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let textWidth = (track.name as NSString).size(withAttributes: [.font: font]).width
            let leftWing = leftFixed + textWidth + notchSideMargin
            let rightWing = rightFixed
            let needed = notchWidth + leftWing + rightWing + pillExtraWidth
            let clamped = min(max(needed, IslandLayout.collapsedWidth), maxCollapsedWidth)
            targetWidth = clamped
            let effectiveLeftWing = clamped - notchWidth - rightWing - pillExtraWidth
            targetOffset = (rightWing - effectiveLeftWing) / 2
        } else if track == nil {
            targetWidth = IslandLayout.collapsedWidth
            targetOffset = 0
        } else {
            targetWidth = 320
            targetOffset = 0
        }
        let needsWidth = abs(targetWidth - dynamicCollapsedWidth) > 0.5
        let needsOffset = abs(targetOffset - dynamicCollapsedOffset) > 0.5
        if needsWidth || needsOffset {
            if animated {
                withAnimation(IslandLayout.spring) {
                    dynamicCollapsedWidth = targetWidth
                    dynamicCollapsedOffset = targetOffset
                }
            } else {
                dynamicCollapsedWidth = targetWidth
                dynamicCollapsedOffset = targetOffset
            }
        }
    }

    var panelHeight: CGFloat {
        // No expanded view — panel only needs compact height
        compactHeight
    }

    func bind(monitor: PlaybackMonitor) {
        cancellable = monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.lastTrack = snap.track
                self?.updateCollapsedWidth(for: snap.track)
                // L'île disparaît en douceur quand aucun média n'est détecté
                let hasMedia = snap.track?.hasContent == true
                let visible = hasMedia || snap.needsPermission
                guard let self, visible != self.isVisible else { return }
                withAnimation(IslandLayout.fastEase) {
                    self.isVisible = visible
                }
            }
    }

    func hoverBegan() {
        // Expanded view removed — no-op, keep compact only
        cancelCollapse()
    }

    func hoverEnded() {
        cancelCollapse()
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }
}
