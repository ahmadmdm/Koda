import SwiftUI
import UIKit

/// iPad helpers. On iPhone these leave the view exactly as it was.

extension UIUserInterfaceIdiom {
    /// Whether wide (side-by-side, capped-width) layouts are allowed: iPad windows with regular width.
    /// A large iPhone in landscape also reports regular width, and keeps its iPhone layout.
    static func allowsWideLayout(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }
}

/// Keeps lists and long text to a comfortable reading width on wide (regular) layouts by
/// adding equal side margins to the scroll content.
struct ReadableContentWidth: ViewModifier {
    var maxWidth: CGFloat = 760
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if UIUserInterfaceIdiom.allowsWideLayout(sizeClass) {
            content
                .contentMargins(.horizontal, max(0, (width - maxWidth) / 2), for: .scrollContent)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        } else {
            content
        }
    }
}

extension View {
    func readableContentWidth(_ maxWidth: CGFloat = 760) -> some View {
        modifier(ReadableContentWidth(maxWidth: maxWidth))
    }
}

/// Full-size video cards: one column on iPhone, as many ~300pt-wide columns as fit on iPad.
struct VideoGrid: View {
    var videos: [Video]
    var spacing: CGFloat = 22

    var body: some View {
        LazyVGrid(columns: UIDevice.current.userInterfaceIdiom == .pad
                  ? [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)]
                  : [GridItem(.flexible())],
                  alignment: .leading, spacing: spacing) {
            ForEach(videos) { VideoCard(video: $0, queue: videos) }
        }
        .padding(.horizontal)
    }
}
