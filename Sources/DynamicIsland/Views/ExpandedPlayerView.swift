import SwiftUI
import AppKit

private var expandedDisplayFPS: Double {
    if #available(macOS 14.0, *) {
        if let fps = NSScreen.main?.maximumFramesPerSecond, fps > 0 {
            return Double(fps)
        }
        let maxFPS = NSScreen.screens.compactMap { $0.maximumFramesPerSecond }.max() ?? 60
        return Double(maxFPS)
    }
    return 60
}

struct ExpandedPlayerView: View {
    @ObservedObject var monitor: PlaybackMonitor
    @ObservedObject var artwork: ArtworkStore
    @ObservedObject var island: IslandState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / expandedDisplayFPS)) { timeline in
            let snap = monitor.snapshot
            let duration = max(snap.track?.duration ?? 0, 0)
            let base = snap.position
            let delta = snap.isPlaying ? timeline.date.timeIntervalSince(snap.updatedAt) : 0
            let rawElapsed = base + delta
            let elapsed = duration > 1 ? min(max(rawElapsed, 0), duration) : max(rawElapsed, 0)
            content(snap: snap, elapsed: elapsed, duration: duration)
        }
        .frame(
            width: IslandLayout.expandedWidth,
            height: IslandLayout.expandedContentHeight,
            alignment: .leading
        )
    }

    @ViewBuilder
    private func content(snap: Snapshot, elapsed: Double, duration: Double) -> some View {
        if snap.needsPermission {
            permissionView
        } else if let track = snap.track, track.hasContent {
            playerView(track: track, snap: snap, elapsed: elapsed, duration: duration)
        } else {
            VStack {
                Spacer()
                Text("Nothing playing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var playerView: some View { self }

    private func playerView(track: Track, snap: Snapshot, elapsed: Double, duration: Double) -> some View {
        let accent = Color(nsColor: artwork.accent)
        return HStack(alignment: .center, spacing: 8) {
            artworkView(accent: accent)
                .padding(.leading, 1)

            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(
                    text: track.name,
                    font: .system(size: 12, weight: .semibold),
                    maxWidth: 240
                )
                .foregroundColor(.white)

                Text(track.artist)
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Scrubber(
                    position: elapsed,
                    duration: duration,
                    accent: accent
                ) { monitor.seek(to: $0) }

                HStack(spacing: 10) {
                    TransportButton(icon: "shuffle", active: snap.shuffle, accent: accent) {
                        monitor.setShuffling(!snap.shuffle)
                    }
                    TransportButton(icon: "backward.fill", size: 11, accent: accent) {
                        monitor.previousTrack()
                    }
                    TransportButton(icon: snap.isPlaying ? "pause.fill" : "play.fill", size: 14, accent: accent) {
                        monitor.playPause()
                    }
                    TransportButton(icon: "forward.fill", size: 11, accent: accent) {
                        monitor.nextTrack()
                    }
                    TransportButton(icon: "repeat", active: snap.repeating, accent: accent) {
                        monitor.setRepeating(!snap.repeating)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                EQBars(playing: snap.isPlaying, color: accent)
                    .frame(width: 24, height: 18)
                VolumeSlider(volume: snap.volume, accent: accent) { monitor.setVolume($0) }
                    .frame(width: 64)
            }
            .frame(width: 64)
            .padding(.trailing, 1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func artworkView(accent: Color) -> some View {
        Group {
            if let image = artwork.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(accent.opacity(0.3))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: accent.opacity(0.4), radius: 8, x: 0, y: 2)
    }

    private var permissionView: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.7))
            Text("Allow Spotify access")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("System Settings → Privacy & Security → Automation")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
    }
}
