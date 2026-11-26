import Foundation

nonisolated struct Song: Codable, Hashable, Identifiable, Sendable {
    var id: String          // videoId
    var title: String
    var artist: String
    var artistId: String?
    var album: String?
    var albumId: String?
    var duration: Int?      // seconds
    var thumbnail: String?
    var isVideo: Bool = false

    /// A file imported into Documents/Music: the id is `local:<file name>` (see `LocalMusicLibrary`).
    var isLocal: Bool { id.hasPrefix(LocalMusicLibrary.idPrefix) }

    var artwork: URL? {
        if isLocal { return LocalMusicLibrary.artworkURL(for: id) }
        return thumbnail.flatMap { URL(string: $0.upscaledThumbnail()) }
    }
    var largeArtwork: URL? {
        if isLocal { return LocalMusicLibrary.artworkURL(for: id) }
        if let t = thumbnail, t.contains("i.ytimg.com") {
            return URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
        }
        return thumbnail.flatMap { URL(string: $0.upscaledThumbnail(1080)) }
    }
}

nonisolated enum MusicKind: String, Codable, Sendable {
    case song, video, album, artist, playlist
}

nonisolated struct MusicCard: Codable, Hashable, Identifiable, Sendable {
    var kind: MusicKind
    var id: String          // videoId for song/video, browseId otherwise
    var title: String
    var subtitle: String
    var thumbnail: String?
    var song: Song?

    var artwork: URL? { thumbnail.flatMap { URL(string: $0.upscaledThumbnail()) } }
}

nonisolated struct MusicShelf: Hashable, Identifiable, Sendable {
    var id: String { title + (items.first?.id ?? "") }
    var title: String
    var items: [MusicCard]
}

nonisolated struct MusicHome: Sendable {
    var shelves: [MusicShelf]
    var continuation: String?
}

nonisolated struct CollectionPage: Sendable {
    var id: String
    var title: String
    var subtitle: String
    var secondSubtitle: String
    var description: String?
    var thumbnail: String?
    var songs: [Song]
    var isAlbum: Bool
}

nonisolated struct ArtistPage: Sendable {
    var id: String
    var name: String
    var subscribers: String?
    var description: String?
    var thumbnail: String?
    var topSongs: [Song]
    var shelves: [MusicShelf]
}

nonisolated struct Video: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var channel: String
    var channelId: String?
    var channelAvatar: String?
    var thumbnail: String?
    var durationText: String?
    var views: String?
    var published: String?
    var isLive: Bool = false
    var publishedDate: Date?

    var thumbnailURL: URL? {
        URL(string: thumbnail ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
    var metaLine: String {
        [views, published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }
    var asSong: Song {
        Song(id: id, title: title, artist: channel, artistId: channelId, duration: durationText?.durationSeconds,
             thumbnail: thumbnail ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", isVideo: true)
    }
}

nonisolated struct ChannelSummary: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var avatar: String?
    var subscribers: String?
    /// For a followed channel: the signed-in accounts (`YouTubeAccount.id`) subscribed to it.
    /// Absent in libraries from before accounts were told apart.
    var accounts: [String]? = nil
    /// For a followed channel: followed on this iPhone, without an account. Absent (with no
    /// accounts) in older libraries, where every follow counts as the device's own.
    var onDevice: Bool? = nil

    /// A follow of the device's own, shown whichever account is active, or none.
    var isDeviceFollow: Bool { onDevice ?? (accounts ?? []).isEmpty }

    /// Shown in Subscriptions while `account` (nil: signed out) is active.
    func isFollowed(by account: String?) -> Bool {
        isDeviceFollow || account.map { (accounts ?? []).contains($0) } ?? false
    }
}

nonisolated struct VideoPlaylistSummary: Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var channel: String
    var thumbnail: String?
    var count: String?
}

nonisolated enum VideoSearchResult: Hashable, Identifiable, Sendable {
    case video(Video), channel(ChannelSummary), playlist(VideoPlaylistSummary)
    var id: String {
        switch self {
        case .video(let v): "v" + v.id
        case .channel(let c): "c" + c.id
        case .playlist(let p): "p" + p.id
        }
    }
}

nonisolated struct WatchDetails: Sendable {
    var id: String
    var title: String
    var views: String
    var date: String
    var description: String
    var channel: ChannelSummary
    var likes: String?
    var related: [Video]
    var commentsToken: String?
    var commentCount: String?
    var liveChat: LiveChatSource? = nil
}

nonisolated struct Comment: Identifiable, Hashable, Sendable {
    var id: String
    var author: String
    var avatar: String?
    var text: String
    var published: String
    var likes: String?
    var replyCount: String?
}

nonisolated struct ChannelPage: Sendable {
    var id: String
    var name: String
    var handle: String?
    var avatar: String?
    var banner: String?
    var subscribers: String?
    var description: String?
    var videos: [Video]
    var videoCount: String? = nil
    var isVerified = false
    /// The channel's tabs as the response lists them, with their own browse params.
    var tabs: [ChannelTab] = []
    /// Continuation that loads the About panel (`aboutChannelViewModel`).
    var aboutToken: String? = nil

    /// The tabs the channel page offers as sections, in YouTube's order.
    var contentTabs: [ChannelTab] { tabs.filter { [.videos, .live, .playlists, .podcasts].contains($0.kind) } }
    /// The tab a channel opens on: Videos, else its first other content tab.
    var defaultTab: ChannelTab? { tabs.first { $0.kind == .videos } ?? contentTabs.first }
    var hasShorts: Bool { tabs.isEmpty || tabs.contains { $0.kind == .shorts } }
}

/// One tab of a channel page. `kind` comes from the tab's URL (`/videos`, `/playlists`, ...), since
/// its title is in the content language; `params` is the tab's own browse params from the response.
nonisolated struct ChannelTab: Hashable, Identifiable, Sendable {
    enum Kind: String, Sendable { case home, videos, shorts, live, playlists, podcasts, other }
    var kind: Kind
    var title: String
    var params: String
    var id: String { params }
}

/// The items of one channel tab and the token of its next page.
nonisolated struct ChannelTabPage: Sendable {
    var videos: [Video] = []
    var playlists: [VideoPlaylistSummary] = []
    var continuation: String?
}

nonisolated struct ChannelLink: Hashable, Identifiable, Sendable {
    var title: String
    var display: String
    var url: URL
    var id: String { url.absoluteString + title }
}

/// A channel's About panel.
nonisolated struct ChannelAbout: Sendable {
    var description: String?
    var links: [ChannelLink] = []
    var joined: String?
    var views: String?
    var country: String?
    var subscribers: String?
    var videos: String?
    var url: String?
}

/// A titled row of videos or playlists on an explore page (a topic channel or the Hype leaderboard).
nonisolated struct VideoShelf: Identifiable, Hashable, Sendable {
    var id: String
    var title: String?
    var videos: [Video] = []
    var playlists: [VideoPlaylistSummary] = []
    var isEmpty: Bool { videos.isEmpty && playlists.isEmpty }
}

nonisolated struct StreamInfo: Sendable {
    var audioURL: URL?
    var lowAudioURL: URL?
    var hlsURL: URL?
    var title: String
    var author: String
    var duration: Double
    var loudnessDb: Double?
    var isLive: Bool
    var thumbnail: String?
    var captions: [CaptionTrack]
    /// BCP-47 tag of the original audio when the video has dubbed tracks (`audioTrack.audioIsDefault`).
    var originalAudioLanguage: String?
}

nonisolated struct CaptionTrack: Hashable, Identifiable, Sendable {
    var id: String { url.absoluteString }
    var isAutoGenerated: Bool = false
    var language: String
    var name: String
    var url: URL
}

nonisolated struct LyricLine: Identifiable, Hashable, Sendable {
    var id: Int
    var time: Double
    var text: String
}

nonisolated struct Lyrics: Sendable {
    var synced: [LyricLine]
    var plain: String?
    var source: String
    var isSynced: Bool { !synced.isEmpty }
}

nonisolated enum AppMode: String, CaseIterable, Identifiable {
    case music, video
    var id: String { rawValue }
    var title: String { self == .music ? String(localized: "Music") : String(localized: "Video") }
    var icon: String { self == .music ? "music.note" : "play.rectangle.fill" }
}
