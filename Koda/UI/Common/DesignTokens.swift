import SwiftUI

/// Spacing on a 4/8-point grid. New and touched layouts use these instead of loose numbers.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner radii, from row artwork up to hero cards. Nested shapes use the outer radius minus the inset.
enum Radius {
    /// Row artwork (44–56pt) and small badges.
    static let small: CGFloat = 6
    /// Grid tiles and compact thumbnails.
    static let medium: CGFloat = 12
    /// Cards and large artwork.
    static let large: CGFloat = 20
    /// Hero artwork and full-width cards.
    static let xLarge: CGFloat = 28
}

/// Sizes of the round glass controls floating over the player, the watch page and Shorts.
enum GlassControl {
    /// The glyph frame of a round glass button; the glass adds its own padding around it.
    static let glassIcon: CGFloat = 44
}

extension View {
    /// A round Liquid Glass button for the controls layer over media: the glyph stays monochrome
    /// (primary), as system bar buttons are, so it reads on any artwork; colour is kept for state.
    func glassIconButton() -> some View {
        buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.primary)
    }

    /// A chip in a row of filters: prominent glass when selected, plain glass with a primary label otherwise.
    func filterChip(selected: Bool) -> some View {
        buttonStyle(selected ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
            .tint(selected ? nil : Color.primary)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
