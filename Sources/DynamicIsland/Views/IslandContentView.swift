import SwiftUI

struct IslandContentView: View {
    @ObservedObject var island: IslandState
    @ObservedObject var monitor: PlaybackMonitor
    @ObservedObject var artwork: ArtworkStore

    var body: some View {
        let size = island.islandSize
        let radius: CGFloat = 26
        let clipShape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        )
        return ZStack(alignment: .top) {
            if island.isExpanded {
                ZStack(alignment: .top) {
                    islandBackground(size: size)
                    ExpandedPlayerView(monitor: monitor, artwork: artwork, island: island)
                        .transition(.opacity.animation(IslandLayout.spring))
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .padding(.top, island.notchHeight)
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(clipShape)
                .animation(IslandLayout.backgroundSpring, value: island.isExpanded)
                .opacity(island.isVisible ? 1 : 0)
            } else {
                CollapsedPillView(monitor: monitor, artwork: artwork, island: island)
                    .transition(.opacity.animation(IslandLayout.spring))
                    .frame(width: IslandLayout.panelWidth, height: island.notchHeight, alignment: .center)
                    // Shift the pill so the invisible `notchWidth` gap inside it lines up with
                    // the hardware notch. The left wing (`artwork + title + 8pt margin`) grows
                    // dynamically with the song title length; the right wing (EQ) stays fixed.
                    .offset(x: island.dynamicCollapsedOffset)
                    .opacity(island.isVisible ? 1 : 0)
            }
        }
        .frame(width: IslandLayout.panelWidth, height: island.panelHeight, alignment: .top)
        .animation(IslandLayout.fastEase, value: island.isVisible)
        .onChange(of: monitor.snapshot.track) { _, newTrack in
            artwork.sync(track: newTrack)
        }
        .onAppear {
            artwork.sync(track: monitor.snapshot.track)
        }
    }

    @ViewBuilder
    private func islandBackground(size: CGSize) -> some View {
        let radius: CGFloat = island.isExpanded ? 26 : 16
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
        .frame(width: size.width, height: size.height)
        .opacity(island.isVisible ? 1 : 0)
    }
}
