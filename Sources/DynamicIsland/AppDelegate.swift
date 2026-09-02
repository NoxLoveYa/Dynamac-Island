import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = PlaybackMonitor()
    let island = IslandState()
    let artwork = ArtworkStore()

    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        island.bind(monitor: monitor)

        let panel = NotchPanel()
        self.panel = panel

        let content = IslandContentView(island: island, monitor: monitor, artwork: artwork)
        let root = IslandRootView(content: content, island: island)
        panel.contentView = root

        applyGeometry()
        panel.orderFrontRegardless()

        setupStatusItem()
        monitor.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyGeometry()
            }
        }
    }

    func applyGeometry() {
        guard let panel,
              let screen = NSScreen.notchScreen ?? NSScreen.main else { return }
        let notch = screen.notchRect
        let width = notch?.width ?? 170
        let height = notch?.height ?? 32

        island.notchWidth = width
        island.notchHeight = height

        let panelHeight = island.panelHeight
        let centerX = notch?.midX ?? screen.frame.midX
        let frame = CGRect(
            x: centerX - IslandLayout.panelWidth / 2,
            y: screen.frame.maxY - panelHeight,
            width: IslandLayout.panelWidth,
            height: panelHeight
        )
        panel.setFrame(frame, display: true)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Dynamic Island")

        let menu = NSMenu()
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            default:
                try service.register()
            }
        } catch {
            NSSound.beep()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let enabled = SMAppService.mainApp.status == .enabled
        for item in menu.items where item.action == #selector(toggleLoginItem) {
            item.state = enabled ? .on : .off
        }
    }
}
