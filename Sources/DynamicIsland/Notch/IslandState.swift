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
    static let panelWidth: CGFloat = 1000
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
    private let notchSideMargin: CGFloat = 8

    // Right wing is fixed: [8 notch gap] + 3 transport buttons + EQ + paddings.
    // Buttons are 28pt circles (TransportButton) with 4pt inter-spacing.
    // Outer HStack spacing is 8, so gap→buttons =8 and buttons→EQ =8.
    // This fixed right side drives the *minimum* collapsed width; the song title on the
    // left drives the *maximum* width via `notchWidth`.
    private var collapsedRightFixed: CGFloat {
        let rightPadding: CGFloat = 16
        let spacingToNotch: CGFloat = 8 // outer HStack 8 between gap and buttonsHStack
        let buttonWidth: CGFloat = 28
        let interButtonSpacing: CGFloat = 4
        let spacingButtonsToEQ: CGFloat = 8 // outerHStack 8 between buttonsHStack and EQ
        let eqWidth: CGFloat = 15
        let buttonCount: CGFloat = 3
        return rightPadding + spacingToNotch + buttonCount * buttonWidth + (buttonCount - 1) * interButtonSpacing + spacingButtonsToEQ + eqWidth
    }

    var islandSize: CGSize {
        isExpanded
            ? CGSize(width: IslandLayout.expandedWidth, height: notchHeight + IslandLayout.expandedContentHeight)
            : CGSize(width: dynamicCollapsedWidth, height: notchHeight)
    }

    /// Maximum width that the title `Text` is allowed to occupy on the left wing
    /// so its trailing edge stops `notchSideMargin` before the notch's left edge.
    var maxLeftTextWidth: CGFloat {
        let leftFixed: CGFloat = 16 + 19 + 8 // left padding + artwork + spacing
        let rightFixed = collapsedRightFixed
        return max(0, dynamicCollapsedWidth - notchWidth - leftFixed - rightFixed - notchSideMargin)
    }

    private var maxCollapsedWidth: CGFloat {
        let panel = IslandLayout.panelWidth
        let panelHalf = panel / 2
        // Pill is hosted in a panel centered on the notch. With an asymmetric pill
        // (left wing grows with the title, right wing fixed) the left edge is
        // `center - leftWing - notchWidth/2`. It must stay inside the panel
        // (`panelHalf` to each side) plus a small margin, otherwise the pill is clipped
        // and the title appears hidden behind the hardware notch.
        let maxLeftWing = max(0, panelHalf - notchWidth / 2 - 12)
        let rightFixed = collapsedRightFixed
        let maxByPanel = maxLeftWing + notchWidth + rightFixed
        // Also respect the menu-bar right-icons area on the screen itself.
        let screenWidth = NSScreen.notchScreen?.frame.width ?? NSScreen.main?.frame.width ?? 1512
        let rightIconsReserve: CGFloat = 180
        let rightEdge = screenWidth - rightIconsReserve
        let maxByScreen = (rightEdge - 12) - 12 // from 12 to rightEdge
        return min(maxByPanel, min(maxByScreen, panel - 16))
    }

    private func updateCollapsedWidth(for track: Track?) {
        let leftFixed: CGFloat = 16 + 19 + 8 // left padding + artwork + inter spacing
        let rightFixed = collapsedRightFixed
        let targetWidth: CGFloat
        let targetOffset: CGFloat
        if let track, track.hasContent {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let textWidth = (track.name as NSString).size(withAttributes: [.font: font]).width
            // Left wing must fit artwork + text and stop `notchSideMargin` before the notch.
            let leftWing = leftFixed + textWidth + notchSideMargin
            let rightWing = rightFixed
            // Total pill width = left wing + physical notch gap + right wing.
            // This uses `notchWidth` so the song title never renders under the hardware cutout.
            let needed = notchWidth + leftWing + rightWing
            let clamped = min(max(needed, IslandLayout.collapsedWidth), maxCollapsedWidth)
            targetWidth = clamped
            // When clamped, the left wing is effectively reduced; keep the notch gap
            // centered on the hardware notch by shifting the whole pill.
            let effectiveLeftWing = clamped - notchWidth - rightWing
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
        notchHeight + IslandLayout.expandedContentHeight + 8
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
        cancelCollapse()
        guard !isExpanded else { return }
        withAnimation(IslandLayout.spring) { isExpanded = true }
    }

    func hoverEnded() {
        cancelCollapse()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(IslandLayout.spring) { self?.isExpanded = false }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }
}
