import Foundation
import AppKit

enum PlayerState: Equatable {
    case stopped
    case playing
    case paused

    init(string: String) {
        switch string.lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        default: self = .stopped
        }
    }
}

struct Track: Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var duration: Double
    var artworkUrl: String

    var hasContent: Bool { !id.isEmpty && !name.isEmpty }
}

struct Snapshot: Equatable {
    var running = false
    var state: PlayerState = .stopped
    var position: Double = 0
    var volume: Int = 0
    var shuffle = false
    var repeating = false
    var track: Track?
    var updatedAt = Date.distantPast
    var needsPermission = false

    var isPlaying: Bool { state == .playing }

    static let empty = Snapshot()
}

final class SpotifyBridge {
    private let sep: Character = "\u{1F}"
    private lazy var pollScript: NSAppleScript? = {
        let src = """
        with timeout of 2 seconds
            tell application "Spotify"
                set ps to player state as string
                set pp to player position
                set sv to sound volume
                set sh to shuffling
                set rp to repeating
                set sep to character id 31
                try
                    set t to current track
                    set tid to id of t
                    set tn to name of t
                    set ta to artist of t
                    set tal to album of t
                    set td to duration of t
                    set tu to artwork url of t
                on error
                    set tid to ""
                    set tn to ""
                    set ta to ""
                    set tal to ""
                    set td to 0
                    set tu to ""
                end try
                return ps & sep & pp & sep & sv & sep & sh & sep & rp & sep & tid & sep & tn & sep & ta & sep & tal & sep & td & sep & tu
            end tell
        end timeout
        """
        return NSAppleScript(source: src)
    }()

    private func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
    }

    func snapshot() -> Snapshot {
        guard isRunning() else { return .empty }
        var result = Snapshot()
        result.running = true
        var descriptor: NSAppleEventDescriptor?
        var error: NSDictionary?
        if Thread.isMainThread {
            descriptor = pollScript?.executeAndReturnError(&error)
        } else {
            DispatchQueue.main.sync {
                descriptor = self.pollScript?.executeAndReturnError(&error)
            }
        }
        if let error = error, error.count > 0 {
            if let code = error[NSAppleScript.errorNumber] as? Int, code == -1743 || code == -1744 {
                result.needsPermission = true
            }
            return result
        }
        guard let desc = descriptor, desc.descriptorType != typeNull else { return result }
        guard let raw = desc.stringValue, !raw.isEmpty else { return result }

        let parts = raw.components(separatedBy: String(sep))
        guard parts.count >= 11 else { return result }

        result.state = PlayerState(string: parts[0])
        result.position = Double(parts[1]) ?? 0
        result.volume = Int(parts[2]) ?? 0
        result.shuffle = parts[3].lowercased() == "true"
        result.repeating = parts[4].lowercased() == "true"

        let tid = parts[5]
        let tn = parts[6]
        let ta = parts[7]
        let tal = parts[8]
        let tdRaw = Double(parts[9]) ?? 0
        let tu = parts[10]

        let duration: Double
        if tdRaw > 10000 {
            duration = tdRaw / 1000.0
        } else {
            duration = tdRaw
        }

        if !tid.isEmpty || !tn.isEmpty {
            result.track = Track(id: tid, name: tn, artist: ta, album: tal, duration: duration, artworkUrl: tu)
        }
        result.updatedAt = Date()
        return result
    }

    func snapshotAsync(completion: @escaping (Snapshot) -> Void) {
        guard isRunning() else { completion(.empty); return }
        DispatchQueue.main.async {
            let snap = self.snapshot()
            completion(snap)
        }
    }

    private func runCommand(_ cmd: String) {
        guard isRunning() else { return }
        let src = "with timeout of 2 seconds\n tell application \"Spotify\" to \(cmd)\n end timeout"
        DispatchQueue.main.async {
            if let script = NSAppleScript(source: src) {
                var err: NSDictionary?
                script.executeAndReturnError(&err)
            }
        }
    }

    func playpause() { runCommand("playpause") }
    func play() { runCommand("play") }
    func pause() { runCommand("pause") }
    func nextTrack() { runCommand("next track") }
    func previousTrack() { runCommand("previous track") }
    func seek(to seconds: Double) {
        let s = String(format: "%.3f", seconds)
        runCommand("set player position to \(s)")
    }
    func setVolume(_ volume: Int) { runCommand("set sound volume to \(volume)") }
    func setShuffling(_ enabled: Bool) { runCommand("set shuffling to \(enabled)") }
    func setRepeating(_ enabled: Bool) { runCommand("set repeating to \(enabled)") }
}
