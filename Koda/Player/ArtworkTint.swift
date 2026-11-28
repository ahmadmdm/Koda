import SwiftUI
import CoreImage
import Observation

/// The dominant colour of the current artwork, used by the "From Artwork"
/// palette and the ambient player backgrounds.
@MainActor
@Observable
final class ArtworkTint {
    static let shared = ArtworkTint()
    var color: Color?
    var colors: [Color] = []
    var image: UIImage?

    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func update(from url: URL?) async {
        // The same download and decode as the Now Playing artwork, which asks for this cover too.
        // The caller's `.task(id:)` is cancelled when the song changes: a cover that arrives late must
        // not replace the next song's colours.
        guard let url, let image = await ArtworkLoader.shared.fullImage(url), !Task.isCancelled else { return }
        self.image = image
        let extracted = await Task.detached(priority: .utility) { [context] in
            Self.extract(image, context: context)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.6)) {
            colors = extracted
            color = extracted.first
        }
    }

    nonisolated private static func extract(_ image: UIImage, context: CIContext) -> [Color] {
        guard let ci = CIImage(image: image) else { return [] }
        let extent = ci.extent
        // Average of the whole image and of four quadrants: a cheap palette.
        let regions = [extent,
                       CGRect(x: extent.minX, y: extent.midY, width: extent.width / 2, height: extent.height / 2),
                       CGRect(x: extent.midX, y: extent.minY, width: extent.width / 2, height: extent.height / 2),
                       CGRect(x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height / 2)]
        return regions.compactMap { rect -> Color? in
            guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: rect)]),
                  let output = filter.outputImage else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            // Keep it vivid enough to read as an accent.
            return Color(hue: Double(h), saturation: Double(max(s, 0.45)), brightness: Double(min(max(b, 0.55), 0.85)))
        }
    }
}
