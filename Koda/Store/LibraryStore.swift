import Foundation
import Observation

nonisolated struct LikedSong: Codable, Hashable, Sendable { var song: Song; var date: Date }

nonisolated struct LocalPlaylist: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var songs: [Song] = []
    var created = Date()
    var coverHue: Double = .random(in: 0...1)
}

nonisolated struct PlayRecord: Codable, Hashable, Sendable {
    var song: Song
    var date: Date
    var seconds: Double
}

nonisolated struct DownloadedSong: Codable, Hashable, Identifiable, Sendable {
    var id: String { song.id }
    var song: Song
    var fileName: String
    var bytes: Int64
    var date: Date
}

nonisolated struct VideoEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String { video.id }
    var video: Video
    var date: Date
    var position: Double = 0
}

/// Everything Koda keeps on the device. One Codable document so backup and
/// restore are a single file, the way Koda's Android backup covers playlists,
/// likes, saved items, statistics, history, subscriptions and settings.
nonisolated struct LibraryData: Codable, Sendable {
    var likedSongs: [LikedSong] = []
    var playlists: [LocalPlaylist] = []
    var plays: [PlayRecord] = []
    var savedCollections: [MusicCard] = []
    var followedArtists: [MusicCard] = []
    var musicSearches: [String] = []
    var videoSearches: [String] = []
    var videoHistory: [VideoEntry] = []
    var watchLater: [VideoEntry] = []
    var likedVideos: [VideoEntry] = []
    var subscriptions: [ChannelSummary] = []
    var hiddenChannels: [ChannelSummary] = []
    var hiddenVideos: [String] = []
    var downloads: [DownloadedSong] = []
    var tasteArtists: [String] = []
}

@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    var data: LibraryData { didSet { derived = Derived(); scheduleSave() } }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Values worked out from `plays`, kept until `data` next changes: Home, Speed dial and CarPlay
    /// ask for them on every render, and each is a pass over up to 20,000 plays.
    private struct Derived {
        var recentSongs: [Song]?
        var topSongs: [Int: [(song: Song, plays: Int, seconds: Double)]] = [:]
        var topArtists: [Int: [(name: String, plays: Int, thumbnail: String?)]] = [:]
    }
    @ObservationIgnored private var derived = Derived()

    init() {
        if let raw = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(LibraryData.self, from: raw) {
            data = decoded
            data.videoSearches = data.videoSearches.map(\.decodingHTMLEntities)
            data.musicSearches = data.musicSearches.map(\.decodingHTMLEntities)
        } else {
            data = LibraryData()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = data, url = url
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if let encoded = try? JSONEncoder().encode(snapshot) { try? encoded.write(to: url, options: .atomic) }
        }
    }

    // MARK: Likes

    func isLiked(_ song: Song) -> Bool { data.likedSongs.contains { $0.song.id == song.id } }

    func toggleLike(_ song: Song) {
        let liked: Bool
        if let i = data.likedSongs.firstIndex(where: { $0.song.id == song.id }) { data.likedSongs.remove(at: i); liked = false }
        else { data.likedSongs.insert(LikedSong(song: song, date: .now), at: 0); liked = true }
        Task { _ = await AccountAPI.setSongLiked(song.id, liked) }
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(_ name: String, songs: [Song] = []) -> LocalPlaylist {
        let p = LocalPlaylist(name: name, songs: songs)
        data.playlists.insert(p, at: 0)
        return p
    }

    func add(_ songs: [Song], to playlistId: UUID) {
        guard let i = data.playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        let existing = Set(data.playlists[i].songs.map(\.id))
        data.playlists[i].songs += songs.filter { !existing.contains($0.id) }
    }

    func playlist(_ id: UUID) -> LocalPlaylist? { data.playlists.first { $0.id == id } }

    func updatePlaylist(_ playlist: LocalPlaylist) {
        guard let i = data.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        data.playlists[i] = playlist
    }

    func deletePlaylist(_ id: UUID) { data.playlists.removeAll { $0.id == id } }

    // MARK: Saved collections / artists

    func isSaved(_ card: MusicCard) -> Bool {
        (card.kind == .artist ? data.followedArtists : data.savedCollections).contains { $0.id == card.id }
    }

    func toggleSaved(_ card: MusicCard) {
        if card.kind == .artist {
            if let i = data.followedArtists.firstIndex(where: { $0.id == card.id }) { data.followedArtists.remove(at: i) }
            else { data.followedArtists.insert(card, at: 0) }
        } else {
            let saved: Bool
            if let i = data.savedCollections.firstIndex(where: { $0.id == card.id }) { data.savedCollections.remove(at: i); saved = false }
            else { data.savedCollections.insert(card, at: 0); saved = true }
            Task { _ = await AccountAPI.setPlaylistSaved(card.id, saved) }
        }
    }

    // MARK: History & statistics

    func recordPlay(_ song: Song, seconds: Double) {
        guard seconds >= 5 else { return }
        data.plays.append(PlayRecord(song: song, date: .now, seconds: seconds))
        if data.plays.count > 20000 { data.plays.removeFirst(data.plays.count - 20000) }
    }

    var recentSongs: [Song] {
        // Read `data` even on a cache hit, so a view using this still updates when the library changes.
        access(keyPath: \.data)
        if let cached = derived.recentSongs { return cached }
        var seen = Set<String>()
        let songs = data.plays.reversed().map(\.song).filter { seen.insert($0.id).inserted }
        derived.recentSongs = songs
        return songs
    }

    func topSongs(since: Date? = nil, limit: Int = 50) -> [(song: Song, plays: Int, seconds: Double)] {
        access(keyPath: \.data)
        if since == nil, let cached = derived.topSongs[limit] { return cached }
        let top = computeTopSongs(since: since, limit: limit)
        if since == nil { derived.topSongs[limit] = top }
        return top
    }

    private func computeTopSongs(since: Date?, limit: Int) -> [(song: Song, plays: Int, seconds: Double)] {
        var counts: [String: (Song, Int, Double)] = [:]
        for p in data.plays where since.map({ p.date >= $0 }) ?? true {
            let c = counts[p.song.id] ?? (p.song, 0, 0)
            counts[p.song.id] = (p.song, c.1 + 1, c.2 + p.seconds)
        }
        return counts.values.sorted { $0.1 == $1.1 ? $0.2 > $1.2 : $0.1 > $1.1 }.prefix(limit).map { ($0.0, $0.1, $0.2) }
    }

    func topArtists(since: Date? = nil, limit: Int = 20) -> [(name: String, plays: Int, thumbnail: String?)] {
        access(keyPath: \.data)
        if since == nil, let cached = derived.topArtists[limit] { return cached }
        let top = computeTopArtists(since: since, limit: limit)
        if since == nil { derived.topArtists[limit] = top }
        return top
    }

    private func computeTopArtists(since: Date?, limit: Int) -> [(name: String, plays: Int, thumbnail: String?)] {
        var counts: [String: (Int, String?)] = [:]
        for p in data.plays where since.map({ p.date >= $0 }) ?? true {
            let name = p.song.artist.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? p.song.artist
            guard !name.isEmpty else { continue }
            let c = counts[name] ?? (0, p.song.thumbnail)
            counts[name] = (c.0 + 1, c.1)
        }
        return counts.sorted { $0.value.0 > $1.value.0 }.prefix(limit).map { ($0.key, $0.value.0, $0.value.1) }
    }

    func plays(since: Date?) -> [PlayRecord] {
        guard let since else { return data.plays }
        return data.plays.filter { $0.date >= since }
    }

    func listeningSeconds(since: Date? = nil) -> Double {
        plays(since: since).reduce(0) { $0 + $1.seconds }
    }

    func playsByHour(since: Date? = nil) -> [Int] {
        var hours = Array(repeating: 0, count: 24)
        let cal = Calendar.current
        for p in data.plays where since.map({ p.date >= $0 }) ?? true { hours[cal.component(.hour, from: p.date)] += 1 }
        return hours
    }

    func playCount(_ songId: String) -> Int { data.plays.filter { $0.song.id == songId }.count }

    // MARK: Search history

    func addSearch(_ query: String, mode: AppMode) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if mode == .music {
            data.musicSearches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
            data.musicSearches.insert(q, at: 0); data.musicSearches = Array(data.musicSearches.prefix(30))
        } else {
            data.videoSearches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
            data.videoSearches.insert(q, at: 0); data.videoSearches = Array(data.videoSearches.prefix(30))
        }
    }

    // MARK: Video

    func recordWatch(_ video: Video, position: Double = 0) {
        data.videoHistory.removeAll { $0.video.id == video.id }
        data.videoHistory.insert(VideoEntry(video: video, date: .now, position: position), at: 0)
        if data.videoHistory.count > 500 { data.videoHistory.removeLast() }
    }

    func savePosition(_ videoId: String, _ position: Double) {
        guard let i = data.videoHistory.firstIndex(where: { $0.video.id == videoId }) else { return }
        data.videoHistory[i].position = position
    }

    func isInWatchLater(_ id: String) -> Bool { data.watchLater.contains { $0.video.id == id } }
    func toggleWatchLater(_ v: Video) {
        if let i = data.watchLater.firstIndex(where: { $0.video.id == v.id }) { data.watchLater.remove(at: i) }
        else {
            data.watchLater.insert(VideoEntry(video: v, date: .now), at: 0)
            Task { _ = await AccountAPI.addToWatchLater(v.id) }
        }
    }

    func isVideoLiked(_ id: String) -> Bool { data.likedVideos.contains { $0.video.id == id } }
    func toggleVideoLike(_ v: Video) {
        let liked: Bool
        if let i = data.likedVideos.firstIndex(where: { $0.video.id == v.id }) { data.likedVideos.remove(at: i); liked = false }
        else { data.likedVideos.insert(VideoEntry(video: v, date: .now), at: 0); liked = true }
        Task { _ = await AccountAPI.setVideoLiked(v.id, liked) }
    }

    func isSubscribed(_ channelId: String) -> Bool { data.subscriptions.contains { $0.id == channelId } }
    func toggleSubscription(_ channel: ChannelSummary) {
        let subscribed: Bool
        if let i = data.subscriptions.firstIndex(where: { $0.id == channel.id }) { data.subscriptions.remove(at: i); subscribed = false }
        else { data.subscriptions.insert(channel, at: 0); subscribed = true }
        Task { _ = await AccountAPI.setSubscribed(channel.id, subscribed) }
    }

    func hideChannel(_ channel: ChannelSummary) {
        guard !data.hiddenChannels.contains(where: { $0.id == channel.id }) else { return }
        data.hiddenChannels.append(channel)
    }

    func isHidden(_ v: Video) -> Bool {
        data.hiddenVideos.contains(v.id) || data.hiddenChannels.contains { $0.id == v.channelId }
    }

    func filtered(_ videos: [Video]) -> [Video] { videos.filter { !isHidden($0) } }

    // MARK: Backup

    func exportBackup() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Koda-backup-\(Date.now.formatted(.iso8601.year().month().day())).json")
        try encoder.encode(data).write(to: file)
        return file
    }

    func importBackup(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var restored = try decoder.decode(LibraryData.self, from: Data(contentsOf: url))
        restored.downloads = data.downloads // downloaded media is not part of a backup
        data = restored
    }

    func clearHistory() { data.plays.removeAll(); data.videoHistory.removeAll() }
}
