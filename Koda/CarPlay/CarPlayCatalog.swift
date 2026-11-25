import Foundation

/// A tile on YouTube Music's Moods & genres page (`FEmusic_moods_and_genres`): its name, the
/// stripe colour YouTube gives it, and the browse params that open its playlists.
nonisolated struct MoodCategory: Hashable, Sendable {
    var title: String
    var params: String
    /// 0xAARRGGBB, from `solid.leftStripeColor`.
    var color: UInt32?
}

nonisolated struct MoodGroup: Hashable, Sendable {
    var title: String
    var categories: [MoodCategory]
}

extension MusicAPI {
    /// Moods & moments, then Genres.
    static func moodsAndGenres() async throws -> [MoodGroup] {
        parseMoods(try await api.music("browse", ["browseId": "FEmusic_moods_and_genres"]))
    }

    static func parseMoods(_ root: J) -> [MoodGroup] {
        root.findAll("gridRenderer").compactMap { grid -> MoodGroup? in
            let title = grid["header"].first("gridHeaderRenderer")["title"].text ?? ""
            let categories = grid["items"].array.compactMap { item -> MoodCategory? in
                let button = item["musicNavigationButtonRenderer"]
                guard let name = button["buttonText"].text, !name.isEmpty,
                      let params = button.path("clickCommand.browseEndpoint.params").string else { return nil }
                let color = button.path("solid.leftStripeColor").int.map { UInt32(truncatingIfNeeded: $0) }
                return MoodCategory(title: name, params: params, color: color)
            }
            return categories.isEmpty ? nil : MoodGroup(title: title, categories: categories)
        }
    }

    /// The playlists of one mood or genre, as carousels (for example "Coffee shop blends").
    static func moodPlaylists(_ category: MoodCategory) async throws -> [MusicShelf] {
        let root = try await api.music("browse", ["browseId": "FEmusic_moods_and_genres_category", "params": category.params])
        return root.findAll("musicCarouselShelfRenderer").compactMap(parseCarousel)
    }
}
