import AppKit
import Combine
import SwiftUI

extension NSScreen {
    var notchRect: CGRect? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else { return nil }
        let height = safeAreaInsets.top
        let x = left.maxX
        let width = right.minX - left.maxX
        return CGRect(x: x, y: frame.maxY - height, width: width, height: height)
    }

    static var notchScreen: NSScreen? {
        screens.first { $0.notchRect != nil }
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
                updateCollapsedWidth(for: lastTrack)
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

    private func updateCollapsedWidth(for track: Track?) {
        let leftFixed = collapsedLeftFixed
        let rightFixed = collapsedRightFixed
        let targetWidth: CGFloat
        let targetOffset: CGFloat
        if let track, track.hasContent {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let textWidth = (track.name as NSString).size(withAttributes: [.font: font]).width
            // Left wing must fit artwork + text and stop `notchSideMargin` before the notch.
            let leftWing = leftFixed + textWidth + notchSideMargin
            let rightWing = rightFixed
            // Total pill width = left wing + physical notch gap + right wing + extra.
            // `notchWidth` keeps the title left of the hardware cutout; `pillExtraWidth`
            // makes the pill slightly bigger (less margin to edges/waveform).
            let needed = notchWidth + leftWing + rightWing + pillExtraWidth
            let clamped = min(max(needed, IslandLayout.collapsedWidth), maxCollapsedWidth)
            targetWidth = clamped
            // When clamped, the left wing is effectively reduced; keep the notch gap
            // centered on the hardware notch by shifting the whole pill.
            // `pillExtraWidth` is split symmetrically, so subtract it for effective left.
            let effectiveLeftWing = clamped - notchWidth - rightWing - pillExtraWidth
            targetOffset = (rightWing - effectiveLeftWing) / 2
        } else if track == nil {
            targetWidth = IslandLayout.collapsedWidth
            targetOffset = 0
        } else {
            targetWidth = 320
            // Balanced centered pill for placeholder state.
            targetOffset = 0
        }
        let needsWidth = abs(targetWidth - dynamicCollapsedWidth) > 0.5
        let needsOffset = abs(targetOffset - dynamicCollapsedOffset) > 0.5
        if needsWidth || needsOffset {
            withAnimation(IslandLayout.spring) {
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
                let visible = true
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
