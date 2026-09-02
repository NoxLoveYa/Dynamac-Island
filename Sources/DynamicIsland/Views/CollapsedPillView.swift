import SwiftUI

struct CollapsedPillView: View {
    @ObservedObject var monitor: PlaybackMonitor
    @ObservedObject var artwork: ArtworkStore
    @ObservedObject var island: IslandState

    private var playing: Bool { monitor.snapshot.isPlaying }

    var body: some View {
        HStack(spacing: 8) {
            artworkThumbnail
            if let track = monitor.snapshot.track, track.hasContent {
                Text(track.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            } else if monitor.snapshot.needsPermission {
                Text("Allow access")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
            } else {
                Text("♪  Dynamic Island")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            Spacer(minLength: 8)
            Group {
                if monitor.snapshot.needsPermission {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    EQBars(playing: playing, color: Color(nsColor: artwork.accent))
                        .frame(width: 15, height: 13)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(width: island.dynamicCollapsedWidth, height: island.notchHeight)
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
