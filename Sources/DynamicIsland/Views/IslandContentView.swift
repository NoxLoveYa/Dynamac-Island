import SwiftUI

struct IslandContentView: View {
    @ObservedObject var island: IslandState
    @ObservedObject var monitor: PlaybackMonitor
    @ObservedObject var artwork: ArtworkStore

    var body: some View {
        return ZStack(alignment: .top) {
            CollapsedPillView(monitor: monitor, artwork: artwork, island: island)
                .transition(.opacity.animation(IslandLayout.spring))
                .frame(width: IslandLayout.panelWidth, height: island.compactHeight, alignment: .center)
                .offset(x: island.dynamicCollapsedOffset)
                .opacity(island.isVisible ? 1 : 0)
        }
        .frame(width: IslandLayout.panelWidth, height: island.panelHeight, alignment: .top)
        .animation(IslandLayout.fastEase, value: island.isVisible)
        .onChange(of: monitor.snapshot) { _, newSnap in
            artwork.sync(snapshot: newSnap)
        }
        .onAppear {
            artwork.sync(snapshot: monitor.snapshot)
        }
    }
}
