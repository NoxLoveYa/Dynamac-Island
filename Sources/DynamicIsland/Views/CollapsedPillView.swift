import SwiftUI

struct CollapsedPillView: View {
    @ObservedObject var monitor: PlaybackMonitor
    @ObservedObject var artwork: ArtworkStore
    @ObservedObject var island: IslandState

    private var playing: Bool { monitor.snapshot.isPlaying }

    var body: some View {
        HStack(spacing: 4) {
            artworkThumbnail
            if let track = monitor.snapshot.track, track.hasContent {
                Text(track.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    // The left wing grows with the title length; clamp the title so its
                    // trailing edge stops 4pt before the hardware notch
                    // (`island.notchWidth` gap) — hug edge.
                    .frame(maxWidth: island.maxLeftTextWidth, alignment: .leading)
            } else if monitor.snapshot.needsPermission {
                Text("Allow access")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
            } else {
                Text("♪  Dynamic Island")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            // Invisible spacer that reserves the physical notch width — hug edge.
            if monitor.snapshot.track?.hasContent == true {
                Color.clear
                    .frame(width: island.notchWidth, height: 1)
            } else {
                Spacer(minLength: 4)
            }
            Group {
                if monitor.snapshot.needsPermission {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                } else if monitor.snapshot.track?.hasContent == true {
                    // Right wing is fixed and balances the dynamic left wing.
                    // Its width (buttons + EQ) drives the *minimum* collapsed width;
                    // the song title on the left drives the *maximum* width.
                    HStack(spacing: 3) {
                        TransportButton(icon: "backward.fill", size: 10, accent: Color(nsColor: artwork.accent)) {
                            monitor.previousTrack()
                        }
                        TransportButton(icon: playing ? "pause.fill" : "play.fill", size: 11, accent: Color(nsColor: artwork.accent)) {
                            monitor.playPause()
                        }
                        TransportButton(icon: "forward.fill", size: 10, accent: Color(nsColor: artwork.accent)) {
                            monitor.nextTrack()
                        }
                    }
                    EQBars(playing: playing, color: Color(nsColor: artwork.accent))
                        .frame(width: 15, height: 13)
                } else {
                    EQBars(playing: playing, color: Color(nsColor: artwork.accent))
                        .frame(width: 15, height: 13)
                }
            }
        }
        .padding(.horizontal, 8)
        .offset(y: -1) // optically center text vertically in taller pill
        .frame(width: island.dynamicCollapsedWidth, height: island.compactHeight)
        .background(
            Color.black,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
    }

    private var artworkThumbnail: some View {
        Group {
            if let image = artwork.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color(nsColor: artwork.accent).opacity(0.35))
            }
        }
        .frame(width: 19, height: 19)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(playing ? 1 : 0.55)
    }
}
