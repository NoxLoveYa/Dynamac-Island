import SwiftUI
import AppKit

private var displayFPS: Double {
    if #available(macOS 14.0, *) {
        if let fps = NSScreen.main?.maximumFramesPerSecond, fps > 0 {
            return Double(fps)
        }
        let maxFPS = NSScreen.screens.compactMap { $0.maximumFramesPerSecond }.max() ?? 60
        return Double(maxFPS)
    }
    return 60
}

struct EQBars: View {
    var playing: Bool
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / displayFPS, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(color)
                        .frame(width: 3, height: barHeight(i, t))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func barHeight(_ index: Int, _ time: Double) -> CGFloat {
        let speeds = [3.4, 4.7, 2.9]
        let phases = [0.0, 1.9, 3.3]
        let s = speeds[index]
        let p = phases[index]
        let a = 0.5 + 0.5 * sin(time * s + p)
        let b = 0.6 + 0.4 * sin(time * s * 1.7 + p * 2.0)
        return CGFloat(3.5 + a * b * 9.5)
    }
}

struct TransportButton: View {
    var icon: String
    var size: CGFloat = 13
    var active = false
    var accent: Color
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(active ? accent : .white.opacity(hovering ? 0.95 : 0.75))
                .frame(width: 28, height: 28)
                .background(
                    active ? Circle().fill(accent.opacity(0.14)) : Circle().fill(.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: hovering)
        .scaleEffect(hovering ? 1.1 : 1)
    }
}

struct Scrubber: View {
    var position: Double
    var duration: Double
    var accent: Color
    var onSeek: (Double) -> Void

    @State private var drag: Double?

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max((drag ?? position) / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.13))
                        .frame(height: 4)
                    Capsule()
                        .fill(accent)
                        .frame(width: max(4, width * fraction), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .opacity(drag != nil ? 1 : 0)
                        .offset(x: width * fraction - 5.5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            drag = min(max(0, value.location.x / width * duration), duration)
                        }
                        .onEnded { _ in
                            if let target = drag { onSeek(target) }
                            drag = nil
                        }
                )
            }
            .frame(height: 15)

            HStack {
                Text(formatTime(drag ?? position))
                Spacer()
                Text("-" + formatTime(max(duration - (drag ?? position), 0)))
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundColor(.white.opacity(0.45))
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

struct VolumeSlider: View {
    var volume: Int
    var accent: Color
    var onChange: (Int) -> Void

    @State private var drag: Int?
    @State private var lastSent = Date.distantPast

    private var fraction: Double {
        min(max(Double(drag ?? volume) / 100.0, 0), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13)).frame(height: 4)
                    Capsule().fill(.white.opacity(0.55)).frame(width: max(3, width * fraction), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let v = min(max(0, Int((value.location.x / width * 100).rounded())), 100)
                            drag = v
                            if Date().timeIntervalSince(lastSent) > 0.09 {
                                lastSent = Date()
                                onChange(v)
                            }
                        }
                        .onEnded { _ in
                            if let v = drag { onChange(v) }
                            drag = nil
                        }
                )
            }
            .frame(height: 16)
            Text("\(drag ?? volume)")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 20, alignment: .trailing)
        }
        .animation(nil, value: drag)
    }
}

struct MarqueeText: View {
    var text: String
    var font: Font
    var maxWidth: CGFloat

    @State private var animate = false

    private var estimatedWidth: CGFloat {
        CGFloat(text.count) * 8.1
    }

    var body: some View {
        Group {
            if estimatedWidth > maxWidth {
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: animate ? -(estimatedWidth - maxWidth + 14) : 0)
                    .onAppear(perform: startAnimating)
                    .onChange(of: text) { _, _ in
                        animate = false
                        startAnimating()
                    }
            } else {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(font)
        .frame(width: maxWidth, alignment: .leading)
        .clipped()
    }

    private func startAnimating() {
        guard estimatedWidth > maxWidth else { return }
        let duration = 2.5 + (estimatedWidth - maxWidth) / 22.0
        withAnimation(.linear(duration: duration).delay(1.2).repeatForever(autoreverses: true)) {
            animate = true
        }
    }
}
