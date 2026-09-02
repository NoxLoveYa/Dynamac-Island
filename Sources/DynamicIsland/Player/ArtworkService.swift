import AppKit

@MainActor
final class ArtworkStore: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var accent: NSColor = .controlAccentColor

    private var currentKey: String?
    private let cache = NSCache<NSString, NSImage>()

    func sync(track: Track?) {
        guard let track, track.hasContent else {
            if currentKey != nil {
                currentKey = nil
                image = nil
                accent = .controlAccentColor
            }
            return
        }
        guard track.id != currentKey else { return }
        currentKey = track.id
        image = nil

        let key = track.id
        let url = track.artworkUrl
        Task { [weak self] in
            let img = await ArtworkService.load(trackId: key, urlString: url)
            guard let self, self.currentKey == key else { return }
            self.image = img
            if let avg = img?.averageColor {
                self.accent = avg.boostedForAccent()
            }
        }
    }
}

enum ArtworkService {
    static func load(trackId: String, urlString: String) async -> NSImage? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DynamicIsland/artwork", isDirectory: true)
        guard let dir else { return nil }
        let fileName = trackId.replacingOccurrences(of: ":", with: "_") + ".img"
        let fileURL = dir.appendingPathComponent(fileName)

        if let data = try? Data(contentsOf: fileURL), let img = NSImage(data: data) {
            return img
        }
        guard let url = URL(string: urlString), !urlString.isEmpty else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let img = NSImage(data: data) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL)
        return img
    }
}

extension NSImage {
    var averageColor: NSColor? {
        var rect = CGRect(origin: .zero, size: size)
        guard let cg = cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.medium.rawValue]) else { return nil }
        return cg.averageColor
    }
}

extension CGImage {
    var averageColor: NSColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(
            red: CGFloat(pixel[0]) / 255.0,
            green: CGFloat(pixel[1]) / 255.0,
            blue: CGFloat(pixel[2]) / 255.0,
            alpha: 1
        )
    }
}

extension NSColor {
    func boostedForAccent() -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.15 + 0.05), brightness: max(b, 0.62), alpha: 1)
    }
}
