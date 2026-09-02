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
                self?.panel?.orderFrontRegardless()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyGeometry()
                self?.panel?.orderFrontRegardless()
            }
        }
        // Garde le panel devant à chaque changement d'écran / wake
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyGeometry()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyGeometry()
                self?.panel?.orderFrontRegardless()
            }
        }
        // Suit le notch en continu pendant les transitions de Spaces (slide) pour paraître fixe derrière la découpe physique
        // 60fps pendant le slide, sinon le panel avec `stationary` reste déjà fixe, mais on force un suivi précis
        // Important : en mode `common` pour tourner pendant le tracking du slide (eventTracking)
        let followTimer = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyGeometryIfNeeded()
            }
        }
        RunLoop.main.add(followTimer, forMode: .common)
        // Poll léger au cas où le notch bouge sans notification (ex: changement de résolution)
        let pollTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyGeometry()
            }
        }
        RunLoop.main.add(pollTimer, forMode: .common)
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
        // Évite de re-set la frame si elle n'a pas bougé (perf)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        } else {
            // Force quand même le layout interne au cas où
            panel.setFrame(frame, display: false)
        }
    }

    func applyGeometryIfNeeded() {
        // Appelé à 60fps : ne fait rien si le notch n'a pas bougé
        // Pour l'instant on appelle applyGeometry qui fait déjà le check `panel.frame != frame`
        applyGeometry()
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
