import Foundation

nonisolated enum VideoSearchFilter: String, CaseIterable, Identifiable, Sendable {
    case all, videos, channels, playlists
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .videos: String(localized: "Videos")
        case .channels: String(localized: "Channels")
        case .playlists: String(localized: "Playlists")
        }
    }
    var params: String? {
        switch self {
        case .all: nil
        case .videos: "EgIQAQ%3D%3D"
        case .channels: "EgIQAg%3D%3D"
        case .playlists: "EgIQAw%3D%3D"
        }
    }
}

nonisolated enum VideoSort: String, CaseIterable, Identifiable, Sendable {
    case relevance, date, views
    var id: String { rawValue }
    var title: String {
        switch self {
        case .relevance: String(localized: "Relevance")
        case .date: String(localized: "Upload date")
        case .views: String(localized: "View count")
        }
    }
    // Sort params for "videos only" searches.
    var params: String? {
        switch self {
        case .relevance: nil
        case .date: "CAISAhAB"
        case .views: "CAMSAhAB"
        }
    }
}

/// Explore topics shown on the video Home, as Koda does when signed out.
nonisolated struct VideoTopic: Hashable, Identifiable, Sendable {
    var id: String { key }
    var key: String
    var title: String { String(localized: String.LocalizationValue(key)) }
    var icon: String
    var query: String

    static let all: [VideoTopic] = [
        .init(key: "For You", icon: "sparkles", query: ""),
        .init(key: "Hype", icon: "flame.fill", query: "trending today"),
        .init(key: "Music", icon: "music.note", query: "new music video"),
        .init(key: "Gaming", icon: "gamecontroller.fill", query: "gaming highlights"),
        .init(key: "News", icon: "newspaper.fill", query: "news today"),
        .init(key: "Sports", icon: "sportscourt.fill", query: "sports highlights"),
        .init(key: "Live", icon: "dot.radiowaves.left.and.right", query: "live now"),
        .init(key: "Tech", icon: "cpu", query: "tech review"),
        .init(key: "Learning", icon: "graduationcap.fill", query: "explained documentary"),
    ]
}

/// YouTube (WEB) calls and their parsers.
nonisolated enum VideoAPI {
    static var api: InnerTube { .shared }

    static func search(_ query: String, filter: VideoSearchFilter, sort: VideoSort = .relevance, continuation: String? = nil) async throws -> ([VideoSearchResult], String?) {
        var body: [String: Any] = [:]
        if let continuation { body["continuation"] = continuation } else {
            body["query"] = query
            if filter == .videos, let p = sort.params { body["params"] = p }
            else if let p = filter.params { body["params"] = p }
        }
        let root = try await api.web("search", body)
        return parseSearch(root)
    }

    static func parseSearch(_ root: J) -> ([VideoSearchResult], String?) {
        var results: [VideoSearchResult] = []
        var seen = Set<String>()
        func add(_ r: VideoSearchResult) { if seen.insert(r.id).inserted { results.append(r) } }
        // Walk item lists in order so the result order matches YouTube's.
        let lists = root.findAll("itemSectionRenderer").map { $0["contents"].array }
            + root.findAll("appendContinuationItemsAction").map { $0["continuationItems"].array }
        for list in lists {
            for item in list {
                if item["videoRenderer"].exists, let v = parseVideoRenderer(item["videoRenderer"]) { add(.video(v)) }
                else if item["channelRenderer"].exists, let c = parseChannelRenderer(item["channelRenderer"]) { add(.channel(c)) }
                else if item["playlistRenderer"].exists, let p = parsePlaylistRenderer(item["playlistRenderer"]) { add(.playlist(p)) }
                else if item["lockupViewModel"].exists {
                    let lockup = item["lockupViewModel"]
                    let type = lockup["contentType"].string ?? ""
                    if type.contains("VIDEO"), let v = parseLockup(lockup) { add(.video(v)) }
                    else if type.contains("PLAYLIST") || type.contains("COURSE"), let p = parseLockupPlaylist(lockup) { add(.playlist(p)) }
                }
            }
        }
        let next = root.findAll("continuationCommand").last?["token"].string
        return (results, next)
    }

    static func feed(topic: VideoTopic, seeds: [String]) async throws -> [Video] {
        if topic.query.isEmpty {
            // "For You": related videos of what was watched recently, else a broad query.
            var videos: [Video] = []
            for seed in seeds.prefix(3) {
                if let details = try? await watch(seed) { videos += details.related }
            }
            if videos.count < 8 {
                videos += try await search("popular videos", filter: .videos).0.compactMap { if case .video(let v) = $0 { v } else { nil } }
            }
            var seen = Set<String>()
            return videos.filter { seen.insert($0.id).inserted }.shuffled()
        }
        return try await search(topic.query, filter: .videos).0.compactMap { if case .video(let v) = $0 { v } else { nil } }
    }

    static func suggestions(_ query: String) async -> [String] {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&xhr=t&oe=utf-8&hl=\(api.language)&gl=\(api.region)&q=\(q)"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return parseSuggestions(data)
    }

    static func parseSuggestions(_ data: Data) -> [String] {
        let root = J(data: data)
        return root[1].array.compactMap { $0[0].string?.decodingHTMLEntities }
    }

    // MARK: Watch page

    static func watch(_ videoId: String) async throws -> WatchDetails {
        let root = try await api.web("next", ["videoId": videoId])
        return parseWatch(root, videoId: videoId)
    }

    static func parseWatch(_ root: J, videoId: String) -> WatchDetails {
        let primary = root.first("videoPrimaryInfoRenderer")
        let secondary = root.first("videoSecondaryInfoRenderer")
        let owner = secondary.path("owner.videoOwnerRenderer")
        let channel = ChannelSummary(
            id: owner.path("navigationEndpoint.browseEndpoint.browseId").string
                ?? owner["title"].runs.first?.path("navigationEndpoint.browseEndpoint.browseId").string ?? "",
            name: owner["title"].text ?? "",
            avatar: owner["thumbnail"].bestThumbnail,
            subscribers: owner["subscriberCountText"].text)
        var related: [Video] = []
        var seen: Set<String> = [videoId]
        for r in root.findAll("lockupViewModel") where (r["contentType"].string ?? "").contains("VIDEO") {
            if let v = parseLockup(r), seen.insert(v.id).inserted { related.append(v) }
        }
        for r in root.findAll("compactVideoRenderer") {
            if let v = parseVideoRenderer(r), seen.insert(v.id).inserted { related.append(v) }
        }
        var commentsToken: String?
        for section in root.findAll("itemSectionRenderer") where section["sectionIdentifier"].string == "comment-item-section" {
            commentsToken = section.findAll("token").first?.string
        }
        let likes = primary.findAll("likeButtonViewModel").first?.findAll("title").first?.string
            ?? primary.findAll("buttonViewModel").first?["title"].string
        let commentCount = root.findAll("commentsEntryPointHeaderRenderer").first?["commentCount"].text
        return WatchDetails(
            id: videoId,
            title: primary["title"].text ?? "",
            views: primary.path("viewCount.videoViewCountRenderer.viewCount").text ?? "",
            date: primary["dateText"].text ?? "",
            description: secondary["attributedDescription"].text ?? secondary["description"].text ?? "",
            channel: channel, likes: likes, related: related,
            commentsToken: commentsToken, commentCount: commentCount)
    }

    static func comments(token: String) async throws -> ([Comment], String?) {
        let root = try await api.web("next", ["continuation": token])
        let (comments, tokens) = parseComments(root)
        if comments.isEmpty, let first = tokens.first, first != token {
            return try await self.comments(token: first)
        }
        return (comments, tokens.last)
    }

    /// The comments on a page, and its continuation tokens in document order.
    /// The first page carries a sort header and the real list token; later pages the next-page token.
    static func parseComments(_ root: J) -> ([Comment], [String]) {
        let mutations = root.findAll("commentEntityPayload")
        let toolbars = Dictionary(root.findAll("engagementToolbarStateEntityPayload").compactMap { t -> (String, J)? in
            guard let key = t["key"].string else { return nil }; return (key, t)
        }, uniquingKeysWith: { a, _ in a })
        let comments = mutations.compactMap { c -> Comment? in
            let p = c["properties"]
            guard let id = p["commentId"].string, let text = p["content"]["content"].string else { return nil }
            return Comment(id: id,
                           author: c.path("author.displayName").string ?? "",
                           avatar: c.path("author.avatarThumbnailUrl").string,
                           text: text,
                           published: p["publishedTime"].string ?? "",
                           likes: c.path("toolbar.likeCountNotliked").string ?? toolbars[p["toolbarStateKey"].string ?? ""]?["likeCount"].string,
                           replyCount: c.path("toolbar.replyCount").string)
        }
        let tokens = root.findAll("continuationCommand").compactMap { $0["token"].string }
        return (comments, tokens)
    }

    // MARK: Channel

    static func channel(_ channelId: String) async throws -> ChannelPage {
        let root = try await api.web("browse", ["browseId": channelId, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        return parseChannel(root, channelId: channelId)
    }

    static func parseChannel(_ root: J, channelId: String) -> ChannelPage {
        let header = root.first("pageHeaderViewModel")
        let name = header["title"].text ?? root.path("metadata.channelMetadataRenderer.title").string ?? ""
        let rows = header.findAll("metadataRows").first?.array ?? []
        let parts = rows.flatMap { $0["metadataParts"].array.compactMap { $0["text"]["content"].string } }
        let videos = root.findAll("lockupViewModel").compactMap(parseLockup)
            + root.findAll("videoRenderer").compactMap(parseVideoRenderer)
        return ChannelPage(
            id: channelId, name: name,
            handle: parts.first { $0.hasPrefix("@") },
            avatar: header["image"].bestThumbnail ?? root.path("metadata.channelMetadataRenderer.avatar").bestThumbnail,
            banner: header["banner"].bestThumbnail,
            subscribers: parts.first { $0.localizedCaseInsensitiveContains("subscriber") },
            description: root.path("metadata.channelMetadataRenderer.description").string,
            videos: videos.map { var v = $0; if v.channel.isEmpty { v.channel = name }; v.channelId = v.channelId ?? channelId; return v })
    }

    /// Public RSS feed of a channel: the subscriptions feed for local follows, without an account.
    static func rssFeed(channelId: String) async -> [Video] {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return ChannelFeedParser.parse(data)
    }

    static func playlist(_ playlistId: String) async throws -> (String, [Video]) {
        let id = playlistId.hasPrefix("VL") ? playlistId : "VL" + playlistId
        let root = try await api.web("browse", ["browseId": id])
        let title = root.path("metadata.playlistMetadataRenderer.title").string ?? root.first("pageHeaderViewModel")["title"].text ?? "Playlist"
        let videos = root.findAll("playlistVideoRenderer").compactMap(parseVideoRenderer)
        return (title, videos)
    }

    // MARK: Parsers

    static func parseVideoRenderer(_ v: J) -> Video? {
        guard let id = v["videoId"].string else { return nil }
        let owner = v["ownerText"].exists ? v["ownerText"] : (v["longBylineText"].exists ? v["longBylineText"] : v["shortBylineText"])
        let isLive = v["badges"].findAll("style").contains { $0.string == "BADGE_STYLE_TYPE_LIVE_NOW" }
            || v["thumbnailOverlays"].findAll("style").contains { $0.string == "LIVE" }
        return Video(
            id: id,
            title: v["title"].text ?? "",
            channel: owner.text ?? "",
            channelId: owner.runs.first?.path("navigationEndpoint.browseEndpoint.browseId").string,
            channelAvatar: v["channelThumbnailSupportedRenderers"].bestThumbnail,
            thumbnail: v["thumbnail"].bestThumbnail,
            durationText: v["lengthText"].text,
            views: v["shortViewCountText"].text ?? v["viewCountText"].text ?? v["videoInfo"].text,
            published: v["publishedTimeText"].text,
            isLive: isLive)
    }

    static func parseLockup(_ l: J) -> Video? {
        guard let id = l["contentId"].string, (l["contentType"].string ?? "VIDEO").contains("VIDEO") else { return nil }
        let meta = l.path("metadata.lockupMetadataViewModel")
        let rows = meta.path("metadata.contentMetadataViewModel.metadataRows").array
        let parts = rows.map { $0["metadataParts"].array.compactMap { $0["text"]["content"].string } }
        let channelRow = parts.count > 1 ? parts[0] : []
        let statRow = parts.count > 1 ? parts[1] : (parts.first ?? [])
        let badge = l.findAll("thumbnailBadgeViewModel").first
        let duration = badge?["text"].string
        let avatarCmd = meta.path("image.decoratedAvatarViewModel")
        return Video(
            id: id,
            title: meta["title"]["content"].string ?? "",
            channel: channelRow.first ?? "",
            channelId: avatarCmd.findAll("browseEndpoint").first?["browseId"].string,
            channelAvatar: avatarCmd.bestThumbnail,
            thumbnail: l["contentImage"].first("image").bestThumbnail ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
            durationText: duration.flatMap { $0.contains(":") ? $0 : nil },
            views: statRow.first,
            published: statRow.count > 1 ? statRow[1] : nil,
            isLive: (duration ?? "").uppercased() == "LIVE")
    }

    static func parseLockupPlaylist(_ l: J) -> VideoPlaylistSummary? {
        guard let id = l["contentId"].string else { return nil }
        let meta = l.path("metadata.lockupMetadataViewModel")
        let rows = meta.path("metadata.contentMetadataViewModel.metadataRows").array
        let first = rows.first?["metadataParts"].array.first?["text"]["content"].string
        return VideoPlaylistSummary(id: id, title: meta["title"]["content"].string ?? "", channel: first ?? "",
                                    thumbnail: l["contentImage"].bestThumbnail,
                                    count: l.findAll("thumbnailBadgeViewModel").first?["text"].string)
    }

    static func parseChannelRenderer(_ c: J) -> ChannelSummary? {
        guard let id = c["channelId"].string else { return nil }
        var avatar = c["thumbnail"].bestThumbnail
        if let a = avatar, a.hasPrefix("//") { avatar = "https:" + a }
        return ChannelSummary(id: id, name: c["title"].text ?? "", avatar: avatar,
                              subscribers: c["videoCountText"].text ?? c["subscriberCountText"].text)
    }

    static func parsePlaylistRenderer(_ p: J) -> VideoPlaylistSummary? {
        guard let id = p["playlistId"].string else { return nil }
        return VideoPlaylistSummary(id: id, title: p["title"].text ?? "", channel: p["shortBylineText"].text ?? "",
                                    thumbnail: p.bestThumbnail, count: p["videoCount"].string)
    }
}

/// Parser for a channel's public Atom feed.
nonisolated final class ChannelFeedParser: NSObject, XMLParserDelegate {
    private var videos: [Video] = []
    private var current: [String: String] = [:]
    private var text = ""
    private var inEntry = false
    private var channelName = ""

    static func parse(_ data: Data) -> [Video] {
        let delegate = ChannelFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.videos
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "entry" { inEntry = true; current = [:] }
        if inEntry, name == "media:thumbnail" { current["thumb"] = attributes["url"] }
        if inEntry, name == "media:statistics" { current["views"] = attributes["views"] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inEntry, name == "name", channelName.isEmpty { channelName = value }
        if inEntry {
            switch name {
            case "yt:videoId": current["id"] = value
            case "yt:channelId": current["channelId"] = value
            case "title": current["title"] = value
            case "name": current["author"] = value
            case "published": current["published"] = value
            case "entry":
                inEntry = false
                if let id = current["id"] {
                    let date = ISO8601DateFormatter().date(from: current["published"] ?? "")
                    var v = Video(id: id, title: current["title"] ?? "", channel: current["author"] ?? channelName,
                                  channelId: current["channelId"], thumbnail: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
                                  views: current["views"].flatMap { Int($0) }.map { "\($0.formatted(.number.notation(.compactName))) views" },
                                  published: date.map { $0.formatted(.relative(presentation: .named)) })
                    v.publishedDate = date
                    videos.append(v)
                }
            default: break
            }
        }
        text = ""
    }
}
