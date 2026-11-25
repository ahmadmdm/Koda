import Foundation

nonisolated enum MusicSearchFilter: String, CaseIterable, Identifiable, Sendable {
    case songs, videos, albums, artists, playlists
    var id: String { rawValue }
    var title: String {
        switch self {
        case .songs: String(localized: "Songs")
        case .videos: String(localized: "Videos")
        case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        case .playlists: String(localized: "Playlists")
        }
    }
    var params: String {
        switch self {
        case .songs: "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        case .videos: "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
        case .albums: "EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D"
        case .artists: "EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D"
        case .playlists: "EgeKAQQoAEABagoQAxAEEAoQCRAF"
        }
    }
}

/// YouTube Music (WEB_REMIX) calls and their parsers.
nonisolated enum MusicAPI {
    static var api: InnerTube { .shared }

    // MARK: Search

    @concurrent static func search(_ query: String, filter: MusicSearchFilter, continuation: String? = nil) async throws -> ([MusicCard], String?) {
        let root: J
        if let continuation {
            root = try await api.music("search", ["continuation": continuation])
        } else {
            root = try await api.music("search", ["query": query, "params": filter.params])
        }
        return parseSearch(root)
    }

    static func parseSearch(_ root: J) -> ([MusicCard], String?) {
        let items = root.findAll("musicResponsiveListItemRenderer").compactMap(parseListItem)
        let next = root.findAll("nextContinuationData").first?["continuation"].string
            ?? root.findAll("continuationCommand").first?["token"].string
        return (items, next)
    }

    @concurrent static func suggestions(_ query: String) async -> [String] {
        guard let root = try? await api.music("music/get_search_suggestions", ["input": query]) else { return [] }
        return root.findAll("searchSuggestionRenderer").compactMap { $0["suggestion"].text }
    }

    // MARK: Home

    @concurrent static func home(continuation: String? = nil) async throws -> MusicHome {
        let root = try await api.music("browse", continuation == nil ? ["browseId": "FEmusic_home"] : ["continuation": continuation!])
        return parseHome(root)
    }

    static func parseHome(_ root: J) -> MusicHome {
        let shelves = root.findAll("musicCarouselShelfRenderer").compactMap(parseCarousel)
        let next = root.findAll("nextContinuationData").first?["continuation"].string
        return MusicHome(shelves: shelves, continuation: next)
    }

    @concurrent static func explore(_ browseId: String) async throws -> [MusicShelf] {
        let root = try await api.music("browse", ["browseId": browseId])
        var shelves = root.findAll("musicCarouselShelfRenderer").compactMap(parseCarousel)
        let list = root.findAll("musicResponsiveListItemRenderer").compactMap(parseListItem)
        if !list.isEmpty { shelves.insert(MusicShelf(title: "Top", items: list), at: 0) }
        return shelves
    }

    // MARK: Collections

    @concurrent static func collection(_ browseId: String) async throws -> CollectionPage {
        let id = browseId.hasPrefix("VL") || browseId.hasPrefix("MPRE") || browseId.hasPrefix("FE") ? browseId : "VL" + browseId
        let root = try await api.music("browse", ["browseId": id])
        return parseCollection(root, id: id)
    }

    static func parseCollection(_ root: J, id: String) -> CollectionPage {
        let header = root.first("musicResponsiveHeaderRenderer").exists ? root.first("musicResponsiveHeaderRenderer")
            : root.first("musicDetailHeaderRenderer").exists ? root.first("musicDetailHeaderRenderer")
            : root.first("musicEditablePlaylistDetailHeaderRenderer")
        let title = header["title"].text ?? root.path("microformat.microformatDataRenderer.title").string ?? "Playlist"
        let strap = header["straplineTextOne"].text ?? ""
        let subtitle = [strap, header["subtitle"].text ?? ""].filter { !$0.isEmpty }.joined(separator: " • ")
        let thumb = header["thumbnail"].bestThumbnail ?? root["background"].bestThumbnail
            ?? root.path("microformat.microformatDataRenderer.thumbnail").bestThumbnail
        let isAlbum = id.hasPrefix("MPRE")
        let artistRun = header["straplineTextOne"].runs.first
        var songs = root.findAll("musicResponsiveListItemRenderer").compactMap { item -> Song? in
            guard let card = parseListItem(item), var song = card.song else { return nil }
            if isAlbum {
                song.thumbnail = song.thumbnail ?? thumb
                song.album = song.album ?? title
                song.albumId = song.albumId ?? id
                if song.artist.isEmpty { song.artist = strap }
                if song.artistId == nil { song.artistId = artistRun?.path("navigationEndpoint.browseEndpoint.browseId").string }
            }
            return song
        }
        var seen = Set<String>()
        songs = songs.filter { seen.insert($0.id).inserted }
        let description = header.path("description.musicDescriptionShelfRenderer.description").text
            ?? root.first("musicDescriptionShelfRenderer")["description"].text
        return CollectionPage(id: id, title: title, subtitle: subtitle, secondSubtitle: header["secondSubtitle"].text ?? "",
                              description: description, thumbnail: thumb, songs: songs, isAlbum: isAlbum)
    }

    @concurrent static func artist(_ browseId: String) async throws -> ArtistPage {
        let root = try await api.music("browse", ["browseId": browseId])
        return parseArtist(root, browseId: browseId)
    }

    static func parseArtist(_ root: J, browseId: String) -> ArtistPage {
        let header = root.first("musicImmersiveHeaderRenderer").exists ? root.first("musicImmersiveHeaderRenderer") : root.first("musicVisualHeaderRenderer")
        let songs = root.findAll("musicShelfRenderer").first.map { shelf in
            shelf.findAll("musicResponsiveListItemRenderer").compactMap { parseListItem($0)?.song }
        } ?? []
        let shelves = root.findAll("musicCarouselShelfRenderer").compactMap(parseCarousel)
        return ArtistPage(
            id: browseId,
            name: header["title"].text ?? "Artist",
            subscribers: header.path("subscriptionButton.subscribeButtonRenderer.subscriberCountText").text,
            description: header["description"].text,
            thumbnail: header["thumbnail"].bestThumbnail ?? header["foregroundThumbnail"].bestThumbnail,
            topSongs: songs, shelves: shelves)
    }

    // MARK: Radio / up next

    @concurrent static func radio(for videoId: String, playlistId: String? = nil) async throws -> [Song] {
        let root = try await api.music("next", ["videoId": videoId, "playlistId": playlistId ?? "RDAMVM\(videoId)", "isAudioOnly": true])
        return parseRadio(root)
    }

    static func parseRadio(_ root: J) -> [Song] {
        root.findAll("playlistPanelVideoRenderer").compactMap(parsePanelItem).filter(isMusicForRadio)
    }

    /// Radio and Quick picks should be music. YouTube's "up next" can drift into user uploads such as
    /// vlogs, podcasts and hour-long mixes; keep official tracks, and user uploads only when song-length.
    nonisolated static func isMusicForRadio(_ song: Song) -> Bool {
        let length = song.duration ?? 0
        if length > 15 * 60 { return false }
        if song.isVideo && length > 8 * 60 { return false }
        return true
    }

    @concurrent static func lyricsBrowseId(for videoId: String) async -> String? {
        guard let root = try? await api.music("next", ["videoId": videoId, "isAudioOnly": true]) else { return nil }
        return root.findAll("tabRenderer").compactMap { $0.path("endpoint.browseEndpoint.browseId").string }
            .first { $0.hasPrefix("MPLY") }
    }

    @concurrent static func youtubeLyrics(for videoId: String) async -> String? {
        guard let id = await lyricsBrowseId(for: videoId),
              let root = try? await api.music("browse", ["browseId": id]) else { return nil }
        return root.first("musicDescriptionShelfRenderer")["description"].text
    }

    // MARK: Parsers

    static func pageType(_ endpoint: J) -> String? {
        endpoint.path("browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType").string
    }

    static func parseListItem(_ item: J) -> MusicCard? {
        let columns = item["flexColumns"].array.map { $0.first("text") }
        guard let title = columns.first?.text, !title.isEmpty else { return nil }
        let thumb = item["thumbnail"].bestThumbnail
        let secondRuns = columns.count > 1 ? columns[1].runs : []
        let subtitle = secondRuns.compactMap { $0["text"].string }.joined()
        let videoId = item.path("playlistItemData.videoId").string
            ?? item.findAll("watchEndpoint").first?["videoId"].string
        let browse = item["navigationEndpoint"]
        if let browseId = browse.path("browseEndpoint.browseId").string {
            let type = pageType(browse) ?? ""
            let kind: MusicKind = type.contains("ARTIST") ? .artist : type.contains("ALBUM") ? .album : .playlist
            return MusicCard(kind: kind, id: browseId, title: title, subtitle: subtitle, thumbnail: thumb)
        }
        guard let videoId else { return nil }
        var artistNames: [String] = [], artistId: String?, album: String?, albumId: String?, duration: Int?
        for run in secondRuns {
            let text = run["text"].string ?? ""
            let nav = run["navigationEndpoint"]
            let type = pageType(nav) ?? ""
            if type.contains("ARTIST") || type.contains("USER_CHANNEL") {
                artistNames.append(text); if artistId == nil { artistId = nav.path("browseEndpoint.browseId").string }
            } else if type.contains("ALBUM") {
                album = text; albumId = nav.path("browseEndpoint.browseId").string
            } else if let d = text.durationSeconds, text.contains(":") {
                duration = d
            }
        }
        if artistNames.isEmpty {
            let parts = subtitle.components(separatedBy: " • ")
            let filtered = parts.filter { !["Song", "Video", "Episode"].contains($0) }
            if let first = filtered.first, first.durationSeconds == nil { artistNames = [first] }
        }
        if duration == nil {
            duration = item["fixedColumns"].array.first?.first("text").text?.durationSeconds
                ?? subtitle.components(separatedBy: " • ").last?.durationSeconds
        }
        let videoType = item.findAll("musicVideoType").first?.string ?? ""
        let isVideo = videoType.contains("UGC")
        let song = Song(id: videoId, title: title, artist: artistNames.joined(separator: ", "), artistId: artistId,
                        album: album, albumId: albumId, duration: duration, thumbnail: thumb, isVideo: isVideo)
        return MusicCard(kind: isVideo ? .video : .song, id: videoId, title: title, subtitle: subtitle, thumbnail: thumb, song: song)
    }

    static func parseTwoRow(_ item: J) -> MusicCard? {
        guard let title = item["title"].text else { return nil }
        let subtitleRuns = item["subtitle"].runs
        let subtitle = item["subtitle"].text ?? ""
        let thumb = item["thumbnailRenderer"].bestThumbnail
        let nav = item["navigationEndpoint"]
        if let videoId = nav.path("watchEndpoint.videoId").string {
            let artistRun = subtitleRuns.first { (pageType($0["navigationEndpoint"]) ?? "").contains("ARTIST") }
            let song = Song(id: videoId, title: title,
                            artist: artistRun?["text"].string ?? subtitle.components(separatedBy: " • ").last ?? subtitle,
                            artistId: artistRun?.path("navigationEndpoint.browseEndpoint.browseId").string,
                            thumbnail: thumb)
            return MusicCard(kind: .song, id: videoId, title: title, subtitle: subtitle, thumbnail: thumb, song: song)
        }
        guard let browseId = nav.path("browseEndpoint.browseId").string else { return nil }
        let type = pageType(nav) ?? ""
        let kind: MusicKind = type.contains("ARTIST") ? .artist : type.contains("ALBUM") ? .album : .playlist
        return MusicCard(kind: kind, id: browseId, title: title, subtitle: subtitle, thumbnail: thumb)
    }

    static func parseCarousel(_ shelf: J) -> MusicShelf? {
        let header = shelf["header"]
        guard let title = header.first("title").text else { return nil }
        let items = shelf["contents"].array.compactMap { c -> MusicCard? in
            if c["musicTwoRowItemRenderer"].exists { return parseTwoRow(c["musicTwoRowItemRenderer"]) }
            if c["musicResponsiveListItemRenderer"].exists { return parseListItem(c["musicResponsiveListItemRenderer"]) }
            return nil
        }
        return items.isEmpty ? nil : MusicShelf(title: title, items: items)
    }

    static func parsePanelItem(_ item: J) -> Song? {
        guard let videoId = item["videoId"].string, let title = item["title"].text else { return nil }
        let runs = item["longBylineText"].runs
        let artistRuns = runs.filter { (pageType($0["navigationEndpoint"]) ?? "").contains("ARTIST") }
        let albumRun = runs.first { (pageType($0["navigationEndpoint"]) ?? "").contains("ALBUM") }
        let artist = artistRuns.isEmpty ? (item["shortBylineText"].text ?? "") : artistRuns.compactMap { $0["text"].string }.joined(separator: ", ")
        let thumbs = item["thumbnail"]["thumbnails"].array
        let thumb = thumbs.last?["url"].string
        return Song(id: videoId, title: title, artist: artist,
                    artistId: artistRuns.first?.path("navigationEndpoint.browseEndpoint.browseId").string,
                    album: albumRun?["text"].string, albumId: albumRun?.path("navigationEndpoint.browseEndpoint.browseId").string,
                    duration: item["lengthText"].text?.durationSeconds, thumbnail: thumb,
                    isVideo: (item.findAll("musicVideoType").first?.string ?? "").contains("UGC"))
    }
}
