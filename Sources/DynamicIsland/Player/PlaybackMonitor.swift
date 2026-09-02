import Foundation
import Combine

final class PlaybackMonitor: ObservableObject {
    private func log(_ msg: String) { }
    @Published private(set) var snapshot = Snapshot.empty

    private let mediaRemote = MediaRemoteBridge.shared
    private let spotifyBridge = AppleScriptBridge(appName: "Spotify", bundleIdentifier: "com.spotify.client")
    private let musicBridge = AppleScriptBridge(appName: "Music", bundleIdentifier: "com.apple.Music")
    private let browserBridge = BrowserBridge.shared
    private var timer: Timer?
    private var lastBrowserCheck = Date.distantPast
    private var lastBrowserSnapshot: Snapshot?
    private var lastBrowserCheckInterval: TimeInterval = 3.5
    private var isCheckingBrowser = false
    // Suivi du dernier média actif (pour afficher le dernier utilisé, pas Spotify par défaut)
    private var lastActiveTimestamps: [String: Date] = [:]
    private var lastActiveBundleID: String?

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func pollSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.poll() }
    }

    private func updateLastActive(for snap: Snapshot) {
        guard let bid = snap.bundleIdentifier, snap.track?.hasContent == true else { return }
        if snap.isPlaying {
            lastActiveTimestamps[bid] = Date()
            lastActiveBundleID = bid
        } else if lastActiveTimestamps[bid] == nil {
            // Première fois en pause, on l'enregistre comme vu mais avec un timestamp plus ancien que les playing
            lastActiveTimestamps[bid] = Date().addingTimeInterval(-5)
            if lastActiveBundleID == nil { lastActiveBundleID = bid }
        }
        // Nettoie les bundles qui ne sont plus en course (plus de hasContent)
        // On garde quand même le timestamp pour le dernier actif
    }

    private func chooseByLastActive(from candidates: [Snapshot]) -> Snapshot? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        // D'abord, les en lecture : le plus récent gagne
        let playing = candidates.filter { $0.isPlaying }
        if !playing.isEmpty {
            return playing.max { a, b in
                let ta = a.bundleIdentifier.flatMap { lastActiveTimestamps[$0] } ?? Date.distantPast
                let tb = b.bundleIdentifier.flatMap { lastActiveTimestamps[$0] } ?? Date.distantPast
                return ta < tb
            }
        }
        // Tous en pause : le dernier actif gagne
        return candidates.max { a, b in
            let ta = a.bundleIdentifier.flatMap { lastActiveTimestamps[$0] } ?? Date.distantPast
            let tb = b.bundleIdentifier.flatMap { lastActiveTimestamps[$0] } ?? Date.distantPast
            return ta < tb
        }
    }

    private func poll() {
        log("poll start isAvailable=\(mediaRemote.isAvailable) current snap=\(snapshot.track?.name ?? "nil")")
        // 1) Essai universel via MediaRemote (toutes les apps)
        if mediaRemote.isAvailable {
            mediaRemote.fetchSnapshot { [weak self] remoteSnap in
                guard let self else { return }
                self.log("fetchSnapshot returned hasContent=\(remoteSnap?.track?.hasContent ?? false) name=\(remoteSnap?.track?.name ?? "nil") bundle=\(remoteSnap?.bundleIdentifier ?? "nil")")
                if let snap = remoteSnap, snap.track?.hasContent == true {
                    self.updateLastActive(for: snap)
                    self.log("using remoteSnap \(snap.track?.name ?? "") != current? \(snap != self.snapshot)")
                    if snap != self.snapshot {
                        self.log("updating snapshot to \(snap.track?.name ?? "")")
                        self.snapshot = snap
                    } else {
                        self.log("snap equal, not updating")
                    }
                    return
                }
                self.log("remote nil or no content -> fallback")
                // Pas de média via MediaRemote -> fallback AppleScript
                self.pollAppleScriptFallback()
            }
        } else {
            pollAppleScriptFallback()
        }
    }

    private func pollAppleScriptFallback() {
        log("fallback start spotifyRunning=\(spotifyBridge.isRunning()) musicRunning=\(musicBridge.isRunning())")
        // Lecture synchrone des bridges AppleScript (rapide, < 2s timeout)
        let spotifySnap: Snapshot = spotifyBridge.isRunning() ? spotifyBridge.snapshot() : .empty
        let musicSnap: Snapshot = musicBridge.isRunning() ? musicBridge.snapshot() : .empty
        log("fallback snap spotify=\(spotifySnap.track?.name ?? "nil") hasContent=\(spotifySnap.track?.hasContent ?? false) music=\(musicSnap.track?.name ?? "nil")")

        // Met à jour le dernier actif pour Spotify/Music
        for snap in [spotifySnap, musicSnap] { updateLastActive(for: snap) }

        let candidatesSync = [spotifySnap, musicSnap].filter { $0.track?.hasContent == true }
        // Choix via dernier actif plutôt que premier playing
        let playingSync = chooseByLastActive(from: candidatesSync.filter { $0.isPlaying }) ?? candidatesSync.first { $0.isPlaying }
        // Pour le cas où on a besoin du dernier actif global (même en pause)
        let bestSyncByLastActive = chooseByLastActive(from: candidatesSync)

        // Si on a un média en lecture via Spotify/Music, on l'affiche immédiatement
        // mais on vérifie quand même les browsers en async pour voir s'il y a un browser en lecture qui devrait prendre le dessus
        let shouldCheckBrowser: Bool
        if let playing = playingSync {
            // Si Spotify/Music joue, on pourrait quand même vérifier si un browser joue aussi
            // mais on priorise Spotify/Music si en lecture, sauf si le browser est aussi en lecture et plus récent
            // Pour l'instant, on affiche directement le playingSync et on check browser en arrière-plan
            shouldCheckBrowser = Date().timeIntervalSince(lastBrowserCheck) > lastBrowserCheckInterval
            if !shouldCheckBrowser {
                let result = playing
                log("fallback immediate playingSync=\(result.track?.name ?? "nil")")
                if result != snapshot {
                    log("updating fallback snapshot to \(result.track?.name ?? "nil")")
                    snapshot = result
                }
                return
            }
        } else {
            shouldCheckBrowser = Date().timeIntervalSince(lastBrowserCheck) > 0.8
        }

        // Pas de lecture en cours via Spotify/Music, ou throttle permet de checker browser
        if shouldCheckBrowser && !isCheckingBrowser {
            lastBrowserCheck = Date()
            isCheckingBrowser = true
            // Check browsers en background pour ne pas bloquer le main
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let browserSnap = self.browserBridge.snapshot()
                DispatchQueue.main.async {
                    self.isCheckingBrowser = false
                    self.handleBrowserResult(browserSnap: browserSnap, spotifySnap: spotifySnap, musicSnap: musicSnap, playingSync: playingSync)
                }
            }
            // En attendant le résultat async, on affiche le meilleur candidat sync (paused) pour ne pas avoir de vide
            if let playing = playingSync {
                if playing != snapshot {
                    log("updating fallback snapshot to playingSync \(playing.track?.name ?? "nil") while waiting browser")
                    snapshot = playing
                }
                return
            }
            let pausedCandidates = candidatesSync
            if let paused = pausedCandidates.first {
                // Si on est déjà sur un browser en lecture, on le garde en attendant le nouveau check
                if let currentID = snapshot.bundleIdentifier, currentID == "company.thebrowser.Browser" && snapshot.isPlaying {
                    log("keeping current browser playing \(snapshot.track?.name ?? "") while waiting")
                    return
                }
                if let cached = lastBrowserSnapshot, cached.isPlaying, cached.track?.hasContent == true {
                    log("keeping cached browser playing \(cached.track?.name ?? "") while waiting")
                    // On garde le cached, pas le paused Spotify
                    if cached != snapshot {
                        snapshot = cached
                    }
                    return
                }
                if paused != snapshot {
                    self.snapshot = paused
                }
                return
            }
            // Aucun candidat sync, on attend le browser (handleBrowserResult gèrera le cas empty)
            // Si on a déjà un snapshot browser, on le garde
            if snapshot.bundleIdentifier == "company.thebrowser.Browser" {
                log("no sync candidate, keeping browser \(snapshot.track?.name ?? "")")
                return
            }
        } else {
            // Throttle : on utilise le cache browser précédent s'il existe, en priorisant le dernier actif
            if let cached = lastBrowserSnapshot, cached.track?.hasContent == true {
                // Met à jour le dernier actif pour le cache aussi
                updateLastActive(for: cached)
                let candidatesWithCache = candidatesSync + [cached]
                if let chosen = chooseByLastActive(from: candidatesWithCache) {
                    if chosen != snapshot {
                        log("using cached browser \(chosen.track?.name ?? "") via lastActive")
                        snapshot = chosen
                    } else {
                        log("keeping cached browser \(chosen.track?.name ?? "")")
                    }
                    return
                }
            }
            // Sinon, on affiche le sync via dernier actif
            let candidates = candidatesSync
            if let chosen = chooseByLastActive(from: candidates) {
                log("fallback throttled result via lastActive \(chosen.track?.name ?? "nil")")
                if chosen != snapshot {
                    log("updating fallback snapshot to \(chosen.track?.name ?? "nil")")
                    snapshot = chosen
                }
                return
            }
            var result: Snapshot
            if let c = chooseByLastActive(from: candidates) { result = c }
            else {
                if spotifySnap.needsPermission { result = spotifySnap }
                else if musicSnap.needsPermission { result = musicSnap }
                else { result = .empty }
            }
            log("fallback throttled result=\(result.track?.name ?? "nil")")
            if result != snapshot {
                log("updating fallback snapshot to \(result.track?.name ?? "nil")")
                snapshot = result
            }
        }
    }

    private func handleBrowserResult(browserSnap: Snapshot?, spotifySnap: Snapshot, musicSnap: Snapshot, playingSync: Snapshot?) {
        if let browser = browserSnap {
            lastBrowserSnapshot = browser
            updateLastActive(for: browser)
            log("browser check returned \(browser.track?.name ?? "nil") isPlaying=\(browser.isPlaying) url=\(browser.track?.album ?? "")")
            // On utilise le dernier actif pour choisir, pas une priorité fixe
            var allCandidates = [spotifySnap, musicSnap].filter { $0.track?.hasContent == true }
            allCandidates.append(browser)
            // Met à jour le dernier actif pour tous
            for snap in allCandidates { updateLastActive(for: snap) }
            if let chosen = chooseByLastActive(from: allCandidates) {
                if chosen != snapshot {
                    log("updating to chosen by lastActive \(chosen.track?.name ?? "") isPlaying=\(chosen.isPlaying) bundle=\(chosen.bundleIdentifier ?? "nil")")
                    snapshot = chosen
                } else {
                    log("keeping chosen \(chosen.track?.name ?? "")")
                }
                return
            }
            // Fallback ancien si choose échoue
            if browser.isPlaying {
                if browser != snapshot {
                    log("updating to browser playing \(browser.track?.name ?? "")")
                    snapshot = browser
                }
                return
            } else {
                if playingSync == nil {
                    let candidates = [spotifySnap, musicSnap].filter { $0.track?.hasContent == true }
                    if candidates.isEmpty {
                        if browser != snapshot {
                            log("updating to browser paused \(browser.track?.name ?? "")")
                            snapshot = browser
                        }
                        return
                    } else {
                        log("browser paused but we have spotify/music paused, keeping current")
                    }
                } else {
                    log("browser paused, keeping playingSync")
                }
            }
        } else {
            log("browser check returned nil")
            lastBrowserSnapshot = nil
            // Aucun browser, on affiche le fallback sync via dernier actif
            let candidates = [spotifySnap, musicSnap].filter { $0.track?.hasContent == true }
            for snap in candidates { updateLastActive(for: snap) }
            if let chosen = chooseByLastActive(from: candidates) {
                if chosen != snapshot {
                    log("updating fallback to sync via lastActive \(chosen.track?.name ?? "nil")")
                    snapshot = chosen
                }
                return
            }
            let playing = candidates.first { $0.isPlaying }
            let chosen = playing ?? candidates.first
            var result: Snapshot
            if let c = chosen { result = c }
            else {
                if spotifySnap.needsPermission { result = spotifySnap }
                else if musicSnap.needsPermission { result = musicSnap }
                else { result = .empty }
            }
            if result != snapshot {
                log("updating fallback to sync after browser nil \(result.track?.name ?? "nil")")
                snapshot = result
            }
        }
    }

    // MARK: - Controls (ciblent le média affiché dans la pill)
    func playPause() {
        // Le contrôle doit agir sur le média actuellement affiché, pas sur le dernier actif système
        if let bid = snapshot.bundleIdentifier {
            if browserBridge.isBrowserBundle(bid) {
                // Contrôle navigateur via JXA (async pour ne pas bloquer)
                DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in
                    browserBridge.togglePlayPause(bundleID: bid)
                }
                pollSoon()
                return
            }
            if bid == musicBridge.bundleIdentifier { musicBridge.playpause(); pollSoon(); return }
            if bid == spotifyBridge.bundleIdentifier { spotifyBridge.playpause(); pollSoon(); return }
        }
        // Si on a un snapshot sans bundleID mais avec un track (ex: MediaRemote), on tente le bundle
        // Sinon fallback : on tente d'abord le média affiché, puis MediaRemote
        if let bid = snapshot.bundleIdentifier, browserBridge.isBrowserBundle(bid) {
            DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.togglePlayPause(bundleID: bid) }
        } else if snapshot.track != nil {
            // On a un affichage mais pas de bundle reconnu -> on tente Spotify/Music selon le displayName
            if snapshot.displayName == "Arc" || snapshot.displayName == "Google Chrome" || snapshot.displayName == "Safari" {
                if let bid = snapshot.bundleIdentifier {
                    DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.togglePlayPause(bundleID: bid) }
                } else {
                    // Fallback générique navigateur
                    DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.togglePlayPause(bundleID: "company.thebrowser.Browser") }
                }
            } else {
                fallbackPlayPause()
            }
        } else {
            // Aucun média affiché : on contrôle le dernier actif via MediaRemote si dispo
            if mediaRemote.isAvailable {
                mediaRemote.sendPlayPause()
            } else {
                fallbackPlayPause()
            }
        }
        pollSoon()
    }

    private func fallbackPlayPause() {
        if let bid = snapshot.bundleIdentifier {
            if browserBridge.isBrowserBundle(bid) {
                DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.togglePlayPause(bundleID: bid) }
                return
            }
            if bid == musicBridge.bundleIdentifier { musicBridge.playpause(); return }
            if bid == spotifyBridge.bundleIdentifier { spotifyBridge.playpause(); return }
        }
        // Pas de snapshot ou inconnu -> on tente le média affiché en priorité, sinon le dernier actif
        if spotifyBridge.isRunning() && (snapshot.bundleIdentifier == spotifyBridge.bundleIdentifier || snapshot.bundleIdentifier == nil) {
            // Si la pill montre Spotify ou rien, on contrôle Spotify
            spotifyBridge.playpause()
        } else if musicBridge.isRunning() {
            musicBridge.playpause()
        } else if let bid = snapshot.bundleIdentifier, browserBridge.isBrowserBundle(bid) {
            DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.togglePlayPause(bundleID: bid) }
        } else if mediaRemote.isAvailable {
            mediaRemote.sendPlayPause()
        } else {
            spotifyBridge.playpause()
        }
    }

    func nextTrack() {
        if let bid = snapshot.bundleIdentifier, browserBridge.isBrowserBundle(bid) {
            DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.nextTrack(bundleID: bid) }
            pollSoon()
            return
        }
        if let bid = snapshot.bundleIdentifier, bid == musicBridge.bundleIdentifier { musicBridge.nextTrack(); pollSoon(); return }
        if let bid = snapshot.bundleIdentifier, bid == spotifyBridge.bundleIdentifier { spotifyBridge.nextTrack(); pollSoon(); return }
        // Sinon, on tente MediaRemote seulement si aucun média affiché (pour ne pas contrôler le mauvais app)
        if snapshot.bundleIdentifier == nil || snapshot.track == nil {
            if mediaRemote.isAvailable { mediaRemote.sendNext() }
            else { fallbackNext() }
        } else {
            fallbackNext()
        }
        pollSoon()
    }

    private func fallbackNext() {
        if let bid = snapshot.bundleIdentifier, browserBridge.isBrowserBundle(bid) {
            DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.nextTrack(bundleID: bid) }
            return
        }
        if let bid = snapshot.bundleIdentifier, bid == musicBridge.bundleIdentifier { musicBridge.nextTrack(); return }
        if spotifyBridge.isRunning() { spotifyBridge.nextTrack() }
        else if musicBridge.isRunning() { musicBridge.nextTrack() }
        else if let bid = snapshot.bundleIdentifier, browserBridge.isBrowserBundle(bid) {
            DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.nextTrack(bundleID: bid) }
        } else {
            spotifyBridge.nextTrack()
        }
    }

    func previousTrack() {
        if let bid = snapshot.bundleIdentifier, browserBridge.isBrowserBundle(bid) {
            DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.previousTrack(bundleID: bid) }
            pollSoon()
            return
        }
        if let bid = snapshot.bundleIdentifier, bid == musicBridge.bundleIdentifier { musicBridge.previousTrack(); pollSoon(); return }
        if let bid = snapshot.bundleIdentifier, bid == spotifyBridge.bundleIdentifier { spotifyBridge.previousTrack(); pollSoon(); return }
        if snapshot.bundleIdentifier == nil || snapshot.track == nil {
            if mediaRemote.isAvailable { mediaRemote.sendPrevious() }
            else { fallbackPrevious() }
        } else {
            fallbackPrevious()
        }
        pollSoon()
    }

    private func fallbackPrevious() {
        if let bid = snapshot.bundleIdentifier, browserBridge.isBrowserBundle(bid) {
            DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.previousTrack(bundleID: bid) }
            return
        }
        if let bid = snapshot.bundleIdentifier, bid == musicBridge.bundleIdentifier { musicBridge.previousTrack(); return }
        if spotifyBridge.isRunning() { spotifyBridge.previousTrack() }
        else if musicBridge.isRunning() { musicBridge.previousTrack() }
        else if let bid = snapshot.bundleIdentifier, browserBridge.isBrowserBundle(bid) {
            DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in browserBridge.previousTrack(bundleID: bid) }
        } else {
            spotifyBridge.previousTrack()
        }
    }

    func seek(to seconds: Double) {
        if let bid = snapshot.bundleIdentifier, browserBridge.isBrowserBundle(bid) {
            DispatchQueue.global(qos: .userInitiated).async { [browserBridge] in
                browserBridge.seek(bundleID: bid, to: seconds)
            }
            pollSoon()
            return
        }
        if snapshot.bundleIdentifier == musicBridge.bundleIdentifier {
            musicBridge.seek(to: seconds)
        } else if snapshot.bundleIdentifier == spotifyBridge.bundleIdentifier {
            spotifyBridge.seek(to: seconds)
        } else {
            // Par défaut on tente MediaRemote seulement si pas de navigateur affiché
            if mediaRemote.isAvailable && snapshot.bundleIdentifier != nil && !browserBridge.isBrowserBundle(snapshot.bundleIdentifier ?? "") {
                mediaRemote.seek(to: seconds)
            } else {
                spotifyBridge.seek(to: seconds)
            }
        }
        pollSoon()
    }

    func setVolume(_ volume: Int) {
        // MediaRemote n'expose pas le volume de façon fiable
        if let bid = snapshot.bundleIdentifier, bid == musicBridge.bundleIdentifier {
            musicBridge.setVolume(volume)
        } else {
            spotifyBridge.setVolume(volume)
            // Aussi essayer Music si Spotify n'est pas la source
            if spotifyBridge.bundleIdentifier != snapshot.bundleIdentifier {
                musicBridge.setVolume(volume)
            }
        }
    }

    func setShuffling(_ enabled: Bool) {
        if mediaRemote.isAvailable {
            mediaRemote.sendToggleShuffle()
        } else if snapshot.bundleIdentifier == musicBridge.bundleIdentifier {
            musicBridge.setShuffling(enabled)
        } else {
            spotifyBridge.setShuffling(enabled)
        }
        pollSoon()
    }

    func setRepeating(_ enabled: Bool) {
        if mediaRemote.isAvailable {
            mediaRemote.sendToggleRepeat()
        } else if snapshot.bundleIdentifier == musicBridge.bundleIdentifier {
            musicBridge.setRepeating(enabled)
        } else {
            spotifyBridge.setRepeating(enabled)
        }
        pollSoon()
    }
}
