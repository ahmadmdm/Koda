import Foundation

/// What signing in adds: the account's identity, YouTube Music library and YouTube feeds, and
/// writes (likes, saves, subscriptions) that sync back to the account. Every call here is made only
/// while an account is signed in, since some endpoints (subscribe, for one) answer 200 signed out.
nonisolated enum AccountAPI {
    static var api: InnerTube { .shared }
    static var isSignedIn: Bool { AccountSession.shared.isSignedIn }

    // MARK: Identity

    /// Name, handle and picture from `account/account_menu`, stored on the account that asked.
    @concurrent static func refreshProfile() async {
        guard let account = AccountSession.shared.active,
              let root = try? await api.music("account/account_menu", [:]) else { return }
        let header = root.first("activeAccountHeaderRenderer")
        AccountSession.shared.updateProfile(
            account.id,
            name: header["accountName"].text,
            handle: header["channelHandle"].text ?? header["email"].text,
            avatar: header["accountPhoto"].bestThumbnail ?? header["avatar"].bestThumbnail,
            datasyncId: nil)
    }

    // MARK: YouTube Music library

    /// Playlists in the account's library (`FEmusic_liked_playlists`): its own and saved ones.
    @concurrent static func libraryPlaylists() async throws -> [MusicCard] {
        let root = try await api.music("browse", ["browseId": "FEmusic_liked_playlists"])
        return root.findAll("musicTwoRowItemRenderer").compactMap(MusicAPI.parseTwoRow)
            .filter { $0.kind == .playlist && $0.id != "VLLM" }
    }

    @concurrent static func libraryAlbums() async throws -> [MusicCard] {
        let root = try await api.music("browse", ["browseId": "FEmusic_liked_albums"])
        return root.findAll("musicTwoRowItemRenderer").compactMap(MusicAPI.parseTwoRow)
    }

    @concurrent static func libraryArtists() async throws -> [MusicCard] {
        let root = try await api.music("browse", ["browseId": "FEmusic_library_corpus_track_artists"])
        return root.findAll("musicResponsiveListItemRenderer").compactMap(MusicAPI.parseListItem).filter { $0.kind == .artist }
    }

    /// The account's "Liked music" playlist.
    @concurrent static func likedSongs() async throws -> [Song] {
        try await MusicAPI.collection("VLLM").songs
    }

    // MARK: Writes

    /// Likes or unlikes a song on the account (music.youtube.com).
    @concurrent static func setSongLiked(_ videoId: String, _ liked: Bool) async -> Bool {
        guard isSignedIn else { return false }
        return (try? await api.music(liked ? "like/like" : "like/removelike", ["target": ["videoId": videoId]])) != nil
    }

    /// Likes or unlikes a video on the account (www.youtube.com).
    @concurrent static func setVideoLiked(_ videoId: String, _ liked: Bool) async -> Bool {
        guard isSignedIn else { return false }
        return (try? await api.web(liked ? "like/like" : "like/removelike", ["target": ["videoId": videoId]])) != nil
    }

    /// Saves an album or playlist to the account's library, or removes it.
    @concurrent static func setPlaylistSaved(_ browseId: String, _ saved: Bool) async -> Bool {
        guard isSignedIn else { return false }
        let id = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        return (try? await api.music(saved ? "like/like" : "like/removelike", ["target": ["playlistId": id]])) != nil
    }

    @concurrent static func setSubscribed(_ channelId: String, _ subscribed: Bool) async -> Bool {
        guard isSignedIn, channelId.hasPrefix("UC") else { return false }
        return (try? await api.web(subscribed ? "subscription/subscribe" : "subscription/unsubscribe", ["channelIds": [channelId]])) != nil
    }

    @concurrent static func addToWatchLater(_ videoId: String) async -> Bool {
        guard isSignedIn else { return false }
        return (try? await api.web("browse/edit_playlist", [
            "playlistId": "WL", "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]],
        ])) != nil
    }

    // MARK: YouTube feeds

    /// The account's own Home feed.
    @concurrent static func videoHome() async throws -> [Video] {
        let root = try await api.web("browse", ["browseId": "FEwhat_to_watch"])
        return videos(in: root)
    }

    /// Uploads from the account's subscriptions, newest first.
    @concurrent static func subscriptionsFeed() async throws -> [Video] {
        let root = try await api.web("browse", ["browseId": "FEsubscriptions"])
        return videos(in: root)
    }

    @concurrent static func watchHistory() async throws -> [Video] {
        let root = try await api.web("browse", ["browseId": "FEhistory"])
        return videos(in: root)
    }

    /// Channels the account is subscribed to (`FEchannels`), every page. `complete` is false when a
    /// later page failed, so the list may be missing some.
    @concurrent static func subscribedChannels() async throws -> (channels: [ChannelSummary], complete: Bool) {
        var root = try await api.web("browse", ["browseId": "FEchannels"])
        var channels: [ChannelSummary] = []
        var seen = Set<String>()
        for _ in 0..<30 {
            channels += root.findAll("channelRenderer").compactMap(VideoAPI.parseChannelRenderer).filter { seen.insert($0.id).inserted }
            guard let token = nextPageToken(root) else { return (channels, true) }
            guard let next = try? await api.web("browse", ["continuation": token]) else { return (channels, false) }
            root = next
        }
        return (channels, false)
    }

    /// The token of a list's next page (its `continuationItemRenderer`).
    static func nextPageToken(_ root: J) -> String? {
        root.findAll("continuationItemRenderer").lazy
            .compactMap { $0.findAll("continuationCommand").first?["token"].string }.first
    }

    private static func videos(in root: J) -> [Video] {
        var seen = Set<String>()
        let all = root.findAll("videoRenderer").compactMap(VideoAPI.parseVideoRenderer)
            + root.findAll("lockupViewModel").compactMap(VideoAPI.parseLockup)
        return all.filter { seen.insert($0.id).inserted }
    }
}
