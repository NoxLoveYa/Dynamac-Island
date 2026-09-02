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
    @Published var notchWidth: CGFloat = 190
    @Published var notchHeight: CGFloat = 32
    @Published var dynamicCollapsedWidth: CGFloat = IslandLayout.collapsedWidth

    private var collapseWork: DispatchWorkItem?
    private var cancellable: AnyCancellable?

    var islandSize: CGSize {
        isExpanded
            ? CGSize(width: IslandLayout.expandedWidth, height: notchHeight + IslandLayout.expandedContentHeight)
            : CGSize(width: dynamicCollapsedWidth, height: notchHeight)
    }

    private var maxCollapsedWidth: CGFloat {
        let panel = IslandLayout.panelWidth
        let screenWidth = NSScreen.notchScreen?.frame.width ?? NSScreen.main?.frame.width ?? 1512
        let center = (NSScreen.notchScreen?.notchRect?.midX) ?? screenWidth / 2
        let rightIconsReserve: CGFloat = 220
        let rightEdge = screenWidth - rightIconsReserve
        let maxHalf = max(0, rightEdge - center - 12)
        let geometricMax = maxHalf * 2
        return min(panel - 24, min(geometricMax, 460))
    }

    private func updateCollapsedWidth(for track: Track?) {
        let base: CGFloat = 19 + 15 + 36 + 16
        let target: CGFloat
        if let track, track.hasContent {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let textWidth = (track.name as NSString).size(withAttributes: [.font: font]).width
            let needed = base + textWidth + 28
            target = min(max(needed, 300), maxCollapsedWidth)
        } else if track == nil {
            target = 300
        } else {
            target = 320
        }
        if abs(target - dynamicCollapsedWidth) > 0.5 {
            withAnimation(IslandLayout.spring) {
                dynamicCollapsedWidth = target
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
