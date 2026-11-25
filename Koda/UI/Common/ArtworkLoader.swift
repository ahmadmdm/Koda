import ImageIO
import SwiftUI
import UIKit

/// Covers and thumbnails for the whole app. Each is downloaded once through a 200 MB disk cache
/// (AsyncImage on iOS 26 goes through `URLSession.shared` and its few megabytes, so covers scrolled
/// past came from the network again), decoded off the main thread at the size it is drawn rather
/// than at 544 or 1080 pixels, and kept decoded in a bounded memory cache, one image per URL.
@MainActor
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 40 << 20, diskCapacity: 200 << 20, directory: nil)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private final class Entry {
        let image: UIImage
        /// Decoded at the file's own size, so it covers any request.
        let isFull: Bool
        init(image: UIImage, isFull: Bool) { self.image = image; self.isFull = isFull }
    }

    private let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()
    private var fullTasks: [URL: Task<UIImage?, Never>] = [:]

    /// The pixel size a view of `size` points needs, rounded up so small layout changes reuse the image.
    nonisolated static func pixelSize(_ size: CGSize, scale: CGFloat) -> CGSize {
        func round(_ v: CGFloat) -> CGFloat { (v * scale / 32).rounded(.up) * 32 }
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return .zero }
        return CGSize(width: round(size.width), height: round(size.height))
    }

    /// A decoded image of `url` big enough to fill `pixels`, if one is in memory.
    func cached(_ url: URL, filling pixels: CGSize) -> UIImage? {
        guard let entry = cache.object(forKey: url as NSURL) else { return nil }
        return entry.isFull || Self.covers(entry.image, pixels) ? entry.image : nil
    }

    /// Any decoded image of `url` in memory, whatever its size: shown while a sharper one loads.
    func anyCached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL)?.image }

    /// The image decoded to fill `pixels` (scaled to fill, so the shorter side matches).
    func image(_ url: URL, filling pixels: CGSize) async -> UIImage? {
        if let hit = cached(url, filling: pixels) { return hit }
        guard let data = await Self.data(url), !Task.isCancelled,
              let image = await Self.decode(data, filling: pixels) else { return nil }
        store(image, for: url, isFull: false)
        return image
    }

    /// The full-size image, one download and decode for everyone asking at once (Now Playing and
    /// the artwork tint ask for the same cover when a song starts).
    func fullImage(_ url: URL) async -> UIImage? {
        if let entry = cache.object(forKey: url as NSURL), entry.isFull { return entry.image }
        if let running = fullTasks[url] { return await running.value }
        let task = Task { () -> UIImage? in
            guard let data = await Self.data(url), let image = await Self.decode(data, filling: .zero) else { return nil }
            self.store(image, for: url, isFull: true)
            return image
        }
        fullTasks[url] = task
        let image = await task.value
        fullTasks[url] = nil
        return image
    }

    private func store(_ image: UIImage, for url: URL, isFull: Bool) {
        // Keep the larger of what is cached and what was just decoded.
        if let existing = cache.object(forKey: url as NSURL),
           existing.isFull || (!isFull && Self.pixels(existing.image) >= Self.pixels(image)) { return }
        cache.setObject(Entry(image: image, isFull: isFull), forKey: url as NSURL, cost: Int(Self.pixels(image)) * 4)
    }

    private nonisolated static func pixels(_ image: UIImage) -> CGFloat {
        image.size.width * image.scale * image.size.height * image.scale
    }

    private nonisolated static func covers(_ image: UIImage, _ target: CGSize) -> Bool {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        guard w > 0, h > 0 else { return false }
        return max(target.width / w, target.height / h) <= 1.05
    }

    @concurrent
    private nonisolated static func data(_ url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }

    /// Decodes on a background thread, downsampled when `pixels` is smaller than the file.
    @concurrent
    private nonisolated static func decode(_ data: Data, filling pixels: CGSize) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var maxPixel: CGFloat = 0
        if pixels.width > 0, pixels.height > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            let scale = max(pixels.width / w, pixels.height / h)
            if scale < 1 { maxPixel = max(w, h) * scale }
        }
        if maxPixel > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded(.up)),
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: thumbnail)
            }
        }
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}
