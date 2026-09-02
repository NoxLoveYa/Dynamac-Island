import AppKit
import SwiftUI
import Combine

final class IslandRootView: NSView {
    private let hosting: NSHostingView<IslandContentView>
    private weak var island: IslandState?
    private var trackingArea: NSTrackingArea?
    private var cancellables = Set<AnyCancellable>()

    init(content: IslandContentView, island: IslandState) {
        self.hosting = NSHostingView(rootView: content)
        self.island = island
        super.init(frame: .zero)
        addSubview(hosting)

        island.$isExpanded
            .combineLatest(island.$isVisible)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncTracking() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        syncTracking()
    }

    private func islandRect(inset: CGFloat = 0) -> CGRect {
        guard let island else { return .zero }
        let size = island.islandSize
        let width = size.width
        let height = size.height + inset
        return CGRect(x: (bounds.width - width) / 2, y: bounds.height - height, width: width, height: height)
    }

    private func syncTracking() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        guard let island, island.isVisible else { return }
        let area = NSTrackingArea(
            rect: islandRect(inset: 6),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let island, island.isVisible else { return nil }
        let local = convert(point, from: nil)
        guard islandRect().contains(local) else { return nil }
        return hosting
    }

    override func mouseEntered(with event: NSEvent) {
        island?.hoverBegan()
    }

    override func mouseExited(with event: NSEvent) {
        island?.hoverEnded()
    }
}
