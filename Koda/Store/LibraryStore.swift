import Foundation
import Observation
import Synchronization

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
    /// The video's length when it was last watched (seconds); older entries have none.
    var duration: Double? = nil
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

/// A key missing from the file (a library or backup from before that list existed) reads as empty.
/// Synthesized decoding would fail the whole document instead, and the next save would then
/// overwrite the user's library with an empty one.
nonisolated extension LibraryData {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list<T: Decodable>(_ key: CodingKeys) throws -> [T] { try c.decodeIfPresent([T].self, forKey: key) ?? [] }
        self.init()
        likedSongs = try list(.likedSongs)
        playlists = try list(.playlists)
        plays = try list(.plays)
        savedCollections = try list(.savedCollections)
        followedArtists = try list(.followedArtists)
        musicSearches = try list(.musicSearches)
        videoSearches = try list(.videoSearches)
        videoHistory = try list(.videoHistory)
        watchLater = try list(.watchLater)
        likedVideos = try list(.likedVideos)
        subscriptions = try list(.subscriptions)
        hiddenChannels = try list(.hiddenChannels)
        hiddenVideos = try list(.hiddenVideos)
        downloads = try list(.downloads)
        tasteArtists = try list(.tasteArtists)
    }
}

/// Writes the library file one snapshot at a time, never an older snapshot over a newer one: the
/// debounced background save and `flush` can otherwise race and leave stale data on disk.
nonisolated final class LibraryWriter: Sendable {
    let url: URL
    private let written = Mutex<Int>(0)

    init(url: URL) { self.url = url }

    func write(_ data: LibraryData, generation: Int) {
        written.withLock { last in
            guard generation > last, let encoded = try? JSONEncoder().encode(data) else { return }
            do {
                try encoded.write(to: url, options: .atomic)
                last = generation
            } catch {}
        }
    }
}

@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    var data: LibraryData { didSet { derived = Derived(); scheduleSave() } }

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let writer = LibraryWriter(url: LibraryStore.fileURL)
    @ObservationIgnored private var generation = 0
    /// The file is there but couldn't be read (still locked, say): saving would replace it.
    @ObservationIgnored private var savingBlocked = false

    /// Values worked out from `plays`, kept until `data` next changes: Home, Speed dial and CarPlay
    /// ask for them on every render, and each is a pass over up to 20,000 plays.
    private struct Derived {
        var recentSongs: [Song]?
        var topSongs: [Int: [(song: Song, plays: Int, seconds: Double)]] = [:]
        var topArtists: [Int: [(name: String, plays: Int, thumbnail: String?)]] = [:]
    }
    @ObservationIgnored private var derived = Derived()

    init() {
        let raw = try? Data(contentsOf: Self.fileURL)
        if let raw, let decoded = try? JSONDecoder().decode(LibraryData.self, from: raw) {
            data = decoded
            data.videoSearches = data.videoSearches.map(\.decodingHTMLEntities)
            data.musicSearches = data.musicSearches.map(\.decodingHTMLEntities)
        } else {
            data = LibraryData()
            let url = Self.fileURL
            if raw != nil {
                // A file that doesn't decode is kept aside rather than overwritten by the first save.
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
            } else if FileManager.default.fileExists(atPath: url.path) {
                savingBlocked = true
            }
        }
    }

    /// Writes the library now, for when the app leaves the screen or quits: the scheduled
    /// save may not get its turn before the process is suspended.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard !savingBlocked else { return }
        generation += 1
        writer.write(data, generation: generation)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard !savingBlocked else { return }
        generation += 1
        let snapshot = data, writer = writer, generation = generation
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            writer.write(snapshot, generation: generation)
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

    /// Puts the video at the top of the history. Its saved position and length stay, and what the
    /// new value doesn't know (a link opens with no title) is kept from the old entry.
    func recordWatch(_ video: Video) {
        let old = data.videoHistory.first { $0.video.id == video.id }
        var entry = VideoEntry(video: video, date: .now, position: old?.position ?? 0, duration: old?.duration)
        if let old { entry.video = Self.merged(video, keeping: old.video) }
        data.videoHistory.removeAll { $0.video.id == video.id }
        data.videoHistory.insert(entry, at: 0)
        if data.videoHistory.count > 500 { data.videoHistory.removeLast() }
    }

    /// Fills in the history entry's title, channel and picture once the player knows them.
    func updateWatchedVideo(_ video: Video) {
        guard let i = data.videoHistory.firstIndex(where: { $0.video.id == video.id }) else { return }
        let merged = Self.merged(video, keeping: data.videoHistory[i].video)
        if merged != data.videoHistory[i].video { data.videoHistory[i].video = merged }
    }

    /// `video`, with the empty or missing fields taken from `old`.
    nonisolated static func merged(_ video: Video, keeping old: Video) -> Video {
        var v = video
        if v.title.isEmpty { v.title = old.title }
        if v.channel.isEmpty { v.channel = old.channel }
        v.channelId = v.channelId ?? old.channelId
        v.channelAvatar = v.channelAvatar ?? old.channelAvatar
        v.thumbnail = v.thumbnail ?? old.thumbnail
        v.durationText = v.durationText ?? old.durationText
        v.views = v.views ?? old.views
        v.published = v.published ?? old.published
        return v
    }

    func savePosition(_ videoId: String, _ position: Double, duration: Double? = nil) {
        guard let i = data.videoHistory.firstIndex(where: { $0.video.id == videoId }) else { return }
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? data.videoHistory[i].duration
        // Unchanged (paused, or saved twice): leave the library, and its save and redraw, alone.
        guard abs(data.videoHistory[i].position - position) >= 0.5 || length != data.videoHistory[i].duration else { return }
        var entry = data.videoHistory[i]
        entry.position = position
        entry.duration = length
        data.videoHistory[i] = entry
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

    /// The active account, as followed channels are tagged with it.
    private var accountKey: String? { AccountSession.shared.active?.id.uuidString }

    /// The followed channels to show: the device's own and the active account's (pass
    /// `AccountModel.active`, so the view redraws when the account changes).
    func subscriptions(for account: YouTubeAccount?) -> [ChannelSummary] {
        FollowedChannels.visible(data.subscriptions, account: account?.id.uuidString)
    }

    func isSubscribed(_ channelId: String) -> Bool {
        let key = accountKey
        return data.subscriptions.contains { $0.id == channelId && $0.isFollowed(by: key) }
    }

    func toggleSubscription(_ channel: ChannelSummary) {
        let subscribed = !isSubscribed(channel.id)
        if subscribed { data.subscriptions = FollowedChannels.subscribing(channel, account: accountKey, into: data.subscriptions) }
        else { unsubscribe(channel.id, sync: false) }
        Task { _ = await AccountAPI.setSubscribed(channel.id, subscribed) }
    }

    /// Unfollows on the device and, when signed in, on the active account.
    func unsubscribe(_ channelId: String, sync: Bool = true) {
        data.subscriptions = FollowedChannels.unsubscribing(channelId, account: accountKey, from: data.subscriptions)
        if sync { Task { _ = await AccountAPI.setSubscribed(channelId, false) } }
    }

    /// The channels an account subscribes to, fetched as that account.
    func importSubscriptions(_ channels: [ChannelSummary], account: UUID, complete: Bool) {
        let updated = FollowedChannels.importing(channels, for: account.uuidString, complete: complete, into: data.subscriptions)
        // Usually nothing changed: leave the library (and its save and redraw) alone then.
        if updated != data.subscriptions { data.subscriptions = updated }
    }

    /// Signed out of these accounts: their channels leave the list.
    func forgetSubscriptions(of accounts: Set<UUID>) {
        let updated = FollowedChannels.forgetting(accounts: Set(accounts.map(\.uuidString)), in: data.subscriptions)
        if updated != data.subscriptions { data.subscriptions = updated }
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
