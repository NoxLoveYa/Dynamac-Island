import Foundation
import Darwin

/// Pont universel vers le système "Now Playing" de macOS.
/// Utilise le framework privé MediaRemote (comme le Control Center).
/// Détecte **n'importe quel** média : Spotify, Apple Music, VLC, IINA, QuickTime,
/// Safari / Chrome / Firefox (YouTube, SoundCloud, etc.), et tout app qui
/// publie via MPNowPlayingInfoCenter / MediaRemote.
final class MediaRemoteBridge {
    private func log(_ msg: String) {
        let line = "[MediaRemote] \(Date()) \(msg)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/dynamic_island.log")
            if FileManager.default.fileExists(atPath: "/tmp/dynamic_island.log") {
                if let fh = try? FileHandle(forWritingTo: url) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
        print(line, terminator: "")
    }
    static let shared = MediaRemoteBridge()

    private var handle: UnsafeMutableRawPointer?
    private var isRegistered = false

    // MARK: - Function pointers
    private typealias MRRegisterFunc = @convention(c) (DispatchQueue) -> Void
    private typealias MRGetInfoBlock = @convention(block) (CFDictionary?) -> Void
    private typealias MRGetInfoFunc = @convention(c) (DispatchQueue, @escaping MRGetInfoBlock) -> Void
    private typealias MRGetClientBlock = @convention(block) (AnyObject?) -> Void
    private typealias MRGetClientFunc = @convention(c) (DispatchQueue, @escaping MRGetClientBlock) -> Void
    private typealias MRGetIsPlayingBlock = @convention(block) (Bool) -> Void
    private typealias MRGetIsPlayingFunc = @convention(c) (DispatchQueue, @escaping MRGetIsPlayingBlock) -> Void
    private typealias MRSendCommandFunc = @convention(c) (UInt32, AnyObject?) -> Void
    private typealias MRSetElapsedFunc = @convention(c) (Double) -> Void

    private var _register: MRRegisterFunc?
    private var _getInfo: MRGetInfoFunc?
    private var _getClient: MRGetClientFunc?
    private var _getIsPlaying: MRGetIsPlayingFunc?
    private var _sendCommand: MRSendCommandFunc?
    private var _setElapsed: MRSetElapsedFunc?

    var isAvailable: Bool { _getInfo != nil && _getClient != nil && _getIsPlaying != nil }

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        guard let h = handle else { return }
        if let sym = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            _register = unsafeBitCast(sym, to: MRRegisterFunc.self)
        }
        if let sym = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") {
            _getInfo = unsafeBitCast(sym, to: MRGetInfoFunc.self)
        }
        if let sym = dlsym(h, "MRMediaRemoteGetNowPlayingClient") {
            _getClient = unsafeBitCast(sym, to: MRGetClientFunc.self)
        }
        if let sym = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            _getIsPlaying = unsafeBitCast(sym, to: MRGetIsPlayingFunc.self)
        }
        if let sym = dlsym(h, "MRMediaRemoteSendCommand") {
            _sendCommand = unsafeBitCast(sym, to: MRSendCommandFunc.self)
        }
        if let sym = dlsym(h, "MRMediaRemoteSetElapsedTime") {
            _setElapsed = unsafeBitCast(sym, to: MRSetElapsedFunc.self)
        }
        if let reg = _register {
            reg(DispatchQueue.main)
            isRegistered = true
            log("registered isAvailable=\(isAvailable)")
        } else {
            log("register nil isAvailable=\(isAvailable)")
        }
    }

    deinit {
        if let h = handle { dlclose(h) }
    }

    // MARK: - Commands (MRMediaRemoteCommand)
    private enum Command: UInt32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
        case advanceShuffleMode = 6
        case advanceRepeatMode = 7
    }

    func sendPlayPause() { _sendCommand?(Command.togglePlayPause.rawValue, nil) }
    func sendPlay() { _sendCommand?(Command.play.rawValue, nil) }
    func sendPause() { _sendCommand?(Command.pause.rawValue, nil) }
    func sendNext() { _sendCommand?(Command.nextTrack.rawValue, nil) }
    func sendPrevious() { _sendCommand?(Command.previousTrack.rawValue, nil) }
    func sendToggleShuffle() { _sendCommand?(Command.advanceShuffleMode.rawValue, nil) }
    func sendToggleRepeat() { _sendCommand?(Command.advanceRepeatMode.rawValue, nil) }
    func seek(to seconds: Double) { _setElapsed?(seconds) }

    // MARK: - Snapshot
    func fetchSnapshot(completion: @escaping (Snapshot?) -> Void) {
        guard let getInfo = _getInfo, let getClient = _getClient, let getIsPlaying = _getIsPlaying else {
            completion(nil)
            return
        }

        var infoDict: NSDictionary?
        var clientBundleID: String?
        var clientDisplayName: String?
        var isPlaying = false
        var isPlayingFetched = false

        let group = DispatchGroup()
        var completed = false
        let lock = NSLock()

        func complete(_ snap: Snapshot?) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()
            DispatchQueue.main.async { completion(snap) }
        }

        group.enter()
        getInfo(DispatchQueue.main) { info in
            if let d = info as NSDictionary? {
                infoDict = d
                self.log("getInfo callback count=\(d.count) keys=\(d.allKeys)")
            } else {
                self.log("getInfo callback nil info=\(String(describing: info))")
            }
            group.leave()
        }

        group.enter()
        getClient(DispatchQueue.main) { client in
            self.log("getClient callback client=\(String(describing: client))")
            if let c = client {
                // Client peut être un dictionnaire ou un objet MRClient
                if let dict = c as? NSDictionary {
                    clientBundleID = dict["bundleIdentifier"] as? String
                    clientDisplayName = dict["displayName"] as? String
                    if clientBundleID == nil {
                        clientBundleID = dict["kMRMediaRemoteNowPlayingClientBundleIdentifier"] as? String
                    }
                } else if let ns = c as? NSObject {
                    clientBundleID = ns.value(forKey: "bundleIdentifier") as? String
                    clientDisplayName = ns.value(forKey: "displayName") as? String
                    // Fallback: parentApplicationBundleIdentifier (for Safari web media)
                    if clientBundleID == nil {
                        clientBundleID = ns.value(forKey: "parentApplicationBundleIdentifier") as? String
                    }
                }
            }
            group.leave()
        }

        group.enter()
        getIsPlaying(DispatchQueue.main) { playing in
            self.log("getIsPlaying callback playing=\(playing)")
            isPlaying = playing
            isPlayingFetched = true
            group.leave()
        }

        group.notify(queue: .main) {
            self.log("notify infoCount=\(infoDict?.count ?? 0) client=\(clientBundleID ?? "nil")/\(clientDisplayName ?? "nil") isPlaying=\(isPlaying) fetched=\(isPlayingFetched)")
            guard let info = infoDict, info.count > 0 else {
                self.log("no info -> nil")
                complete(nil)
                return
            }
            self.log("parsing snap")
            let snap = Self.parseSnapshot(
                info: info,
                bundleID: clientBundleID,
                displayName: clientDisplayName,
                isPlaying: isPlaying,
                isPlayingFetched: isPlayingFetched
            )
            complete(snap)
        }

        // Timeout de sécurité : MediaRemote doit répondre < 1.5s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            lock.lock()
            let already = completed
            lock.unlock()
            if !already {
                self.log("timeout -> nil")
                complete(nil)
            }
        }
    }

    /// Version synchrone avec sémaphore pour compatibilité avec l'ancien polling.
    func fetchSnapshotSync() -> Snapshot? {
        var result: Snapshot?
        var finished = false
        let sem = DispatchSemaphore(value: 0)
        fetchSnapshot { snap in
            result = snap
            finished = true
            sem.signal()
        }
        if Thread.isMainThread {
            let deadline = Date().addingTimeInterval(1.6)
            while !finished && Date() < deadline {
                _ = sem.wait(timeout: .now() + 0.05)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        } else {
            _ = sem.wait(timeout: .now() + 1.6)
        }
        return result
    }

    // MARK: - Parsing
    private static func parseSnapshot(
        info: NSDictionary,
        bundleID: String?,
        displayName: String?,
        isPlaying: Bool,
        isPlayingFetched: Bool
    ) -> Snapshot? {
        // Helpers pour lire des valeurs qui peuvent être String ou NSNumber
        func string(for keys: [String]) -> String? {
            for k in keys {
                if let s = info[k] as? String, !s.isEmpty { return s }
                if let n = info[k] as? NSString { let s = n as String; if !s.isEmpty { return s } }
            }
            return nil
        }
        func double(for keys: [String]) -> Double? {
            for k in keys {
                if let n = info[k] as? NSNumber { return n.doubleValue }
                if let s = info[k] as? String, let d = Double(s) { return d }
                if let d = info[k] as? Double { return d }
            }
            return nil
        }
        func data(for keys: [String]) -> Data? {
            for k in keys {
                if let d = info[k] as? Data, !d.isEmpty { return d }
                if let d = info[k] as? NSData { return d as Data }
            }
            return nil
        }

        let title = string(for: ["kMRMediaRemoteNowPlayingInfoTitle", "title"]) ?? ""
        let artist = string(for: ["kMRMediaRemoteNowPlayingInfoArtist", "artist"]) ?? ""
        let album = string(for: ["kMRMediaRemoteNowPlayingInfoAlbum", "album"]) ?? ""
        let duration = double(for: ["kMRMediaRemoteNowPlayingInfoDuration", "duration", "kMRMediaRemoteNowPlayingInfoTotalTime"]) ?? 0
        let elapsed = double(for: ["kMRMediaRemoteNowPlayingInfoElapsedTime", "elapsedTime", "kMRMediaRemoteNowPlayingInfoCurrentTime"]) ?? 0
        let artworkData = data(for: ["kMRMediaRemoteNowPlayingInfoArtworkData", "artworkData", "artwork"])
        let identifier = string(for: ["kMRMediaRemoteNowPlayingInfoContentItemIdentifier", "kMRMediaRemoteNowPlayingInfoUniqueIdentifier", "uniqueIdentifier", "id"])

        // Si pas de titre et pas d'artiste, on considère qu'il n'y a pas de média
        // (parfois MediaRemote garde un ancien artwork sans titre)
        if title.isEmpty && artist.isEmpty && album.isEmpty && artworkData == nil {
            return nil
        }

        // Fallback id: title + artist + album
        let trackId: String
        if let id = identifier, !id.isEmpty {
            trackId = id
        } else if !title.isEmpty || !artist.isEmpty {
            trackId = "\(bundleID ?? "unknown"):\(title):\(artist):\(album)"
        } else {
            trackId = bundleID ?? "unknown"
        }

        let trackName = title.isEmpty ? (artist.isEmpty ? (album.isEmpty ? "Lecture en cours" : album) : artist) : title

        var snap = Snapshot()
        snap.running = true
        snap.state = isPlaying ? .playing : .paused
        // Si isPlaying n'a pas été fetché, on tente de deviner via info
        if !isPlayingFetched {
            if let playingFlag = info["kMRMediaRemoteNowPlayingInfoIsPlaying"] as? Bool {
                snap.state = playingFlag ? .playing : .paused
            } else if let num = info["kMRMediaRemoteNowPlayingInfoIsPlaying"] as? NSNumber {
                snap.state = num.boolValue ? .playing : .paused
            }
        }
        snap.position = elapsed
        snap.track = Track(
            id: trackId,
            name: trackName,
            artist: artist,
            album: album,
            duration: duration,
            artworkUrl: "" // l'artwork vient via artworkData
        )
        snap.bundleIdentifier = bundleID
        snap.displayName = displayName ?? bundleID?.components(separatedBy: ".").last?.capitalized
        snap.artworkData = artworkData
        snap.updatedAt = Date()
        // Certaines infos comme volume/shuffle/repeat ne sont pas exposées via MediaRemote de façon fiable
        // On les laisse à 0/false
        snap.volume = 0
        snap.shuffle = false
        snap.repeating = false
        return snap
    }
}
