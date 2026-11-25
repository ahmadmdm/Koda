import UIKit

/// Artwork for the car screen: downloaded covers kept in a small memory cache (lists are rebuilt
/// often, and the head unit asks for the same covers again), and tiles drawn on the phone for
/// mixes and moods so they show instantly, even without a signal.
@MainActor
enum CarPlayArtwork {
    private static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 300
        return c
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    static func cached(_ url: URL?) -> UIImage? {
        url.flatMap { cache.object(forKey: $0 as NSURL) }
    }

    static func image(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let image: UIImage?
        if url.isFileURL {
            image = UIImage(contentsOfFile: url.path)
        } else {
            image = (try? await session.data(from: url)).flatMap { UIImage(data: $0.0) }
        }
        // Covers come at 544 px; the largest CarPlay slot is far smaller.
        guard let image else { return nil }
        let small = image.preparingThumbnail(of: CGSize(width: 300, height: 300)) ?? image
        cache.setObject(small, forKey: url as NSURL)
        return small
    }

    static var placeholder: UIImage {
        UIImage(systemName: "music.note")!.withTintColor(.systemGray, renderingMode: .alwaysOriginal)
    }

    static func symbol(_ name: String, tint: UIColor = .systemPink) -> UIImage {
        (UIImage(systemName: name) ?? placeholder).withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    /// A square gradient tile with a white symbol, for mixes and moods.
    static func tile(symbol: String, colors: [UIColor], size: CGFloat = 240) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: rect, format: format).image { ctx in
            let cg = ctx.cgContext
            let cgColors = (colors.isEmpty ? [.systemPink, .systemPurple] : colors).map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: nil) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.36, weight: .semibold)
            if let glyph = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let s = glyph.size
                glyph.draw(in: CGRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
            }
        }
    }

    /// Two shades of one colour for a gradient tile.
    static func shades(_ base: UIColor) -> [UIColor] {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return [UIColor(hue: h, saturation: min(1, s * 0.9), brightness: min(1, b * 1.05 + 0.1), alpha: 1),
                UIColor(hue: h, saturation: min(1, s + 0.1), brightness: max(0.2, b * 0.55), alpha: 1)]
    }

    static func color(argb: UInt32) -> UIColor {
        UIColor(red: CGFloat((argb >> 16) & 0xff) / 255, green: CGFloat((argb >> 8) & 0xff) / 255,
                blue: CGFloat(argb & 0xff) / 255, alpha: 1)
    }
}
