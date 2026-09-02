import Foundation
import Combine

final class PlaybackMonitor: ObservableObject {
    @Published private(set) var snapshot = Snapshot.empty

    private let bridge = SpotifyBridge()
    private var timer: Timer?

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

    private func poll() {
        bridge.snapshotAsync { [weak self] snap in
            guard let self else { return }
            if snap != self.snapshot {
                self.snapshot = snap
            }
        }
    }

    func playPause() { bridge.playpause(); pollSoon() }
    func nextTrack() { bridge.nextTrack(); pollSoon() }
    func previousTrack() { bridge.previousTrack(); pollSoon() }
    func seek(to seconds: Double) { bridge.seek(to: seconds); pollSoon() }
    func setVolume(_ volume: Int) { bridge.setVolume(volume) }
    func setShuffling(_ enabled: Bool) { bridge.setShuffling(enabled); pollSoon() }
    func setRepeating(_ enabled: Bool) { bridge.setRepeating(enabled); pollSoon() }
}
