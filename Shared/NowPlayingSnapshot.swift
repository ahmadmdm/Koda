import Foundation

/// What the app shares with its widgets through the App Group: the song playing, its timing,
/// what comes next and a small copy of the artwork.
nonisolated struct NowPlayingSnapshot: Codable, Hashable, Sendable {
    struct Item: Codable, Hashable, Sendable {
        var title: String
        var artist: String
    }

    var title: String
    var artist: String
    var album: String?
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double
    var capturedAt: Date
    var isLiked: Bool
    var upNext: [Item]
    var tintHex: String?

    /// From Info.plist, so builds signed with another team's identifiers share the right container.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "KodaAppGroup") as? String ?? "group.com.koda.ios"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var fileURL: URL? { containerURL?.appendingPathComponent("now-playing.json") }
    static var artworkURL: URL? { containerURL?.appendingPathComponent("now-playing-artwork.jpg") }

    static func load() -> NowPlayingSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// When the song started, measured on the clock, for live progress in a widget.
    var startDate: Date { capturedAt.addingTimeInterval(-elapsed) }
    var endDate: Date { startDate.addingTimeInterval(max(duration, 1)) }
    var progress: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }

    static let placeholder = NowPlayingSnapshot(
        title: "Koda", artist: "Music & video", album: nil, isPlaying: false, elapsed: 72, duration: 214,
        capturedAt: .now, isLiked: false,
        upNext: [.init(title: "Up next", artist: "Koda")], tintHex: "6650A4")
}
