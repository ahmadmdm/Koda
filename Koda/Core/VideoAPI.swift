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
///
/// YouTube retired its Trending page in 2025: `FEtrending`, `FEexplore` and `FEgaming` answer HTTP 400.
/// Its Explore menu now opens the Hype leaderboard and one official topic channel per subject, and
/// those pages follow the request's `gl`/`hl` (with gl=SA, hl=ar: Saudi Hype, Arabic news and sports).
/// Verified November 2026, signed out, WEB browse: each id below answers with videos.
nonisolated struct VideoTopic: Hashable, Identifiable, Sendable {
    enum Source: Hashable, Sendable {
        /// Related videos of the watch history (or the account's home when signed in).
        case forYou
        /// A browse page: the Hype leaderboard or a topic channel.
        case browse(String)
        /// A search, for a subject without a topic channel, in the content language.
        case search(en: String, ar: String)
    }

    var id: String { key }
    var key: String
    var title: String { String(localized: String.LocalizationValue(key)) }
    var icon: String
    var source: Source
    /// The query of the Shorts shelf above the feed, in English and in Arabic.
    var shortsEn: String
    var shortsAr: String

    func shortsQuery(language: String) -> String { language == "ar" ? shortsAr : shortsEn }

    static let hypeBrowseId = "FEhype_leaderboard"

    static let all: [VideoTopic] = [
        .init(key: "For You", icon: "sparkles", source: .forYou, shortsEn: "trending shorts", shortsAr: "ترند شورتس"),
        .init(key: "Hype", icon: "flame.fill", source: .browse(hypeBrowseId), shortsEn: "trending shorts", shortsAr: "ترند شورتس"),
        .init(key: "Music", icon: "music.note", source: .browse("UC-9-kyTW8ZkZNDHQJ6FgpwQ"), shortsEn: "music shorts", shortsAr: "موسيقى شورتس"),
        .init(key: "Gaming", icon: "gamecontroller.fill", source: .browse("UCOpNcN46UbXVtpKMrmU4Abg"), shortsEn: "gaming shorts", shortsAr: "ألعاب شورتس"),
        .init(key: "News", icon: "newspaper.fill", source: .browse("UCYfdidRxbB8Qhf0Nx7ioOYw"), shortsEn: "news shorts", shortsAr: "أخبار شورتس"),
        .init(key: "Sports", icon: "sportscourt.fill", source: .browse("UCEgdi0XIXXZ-qJOFPf4JSKw"), shortsEn: "sports shorts", shortsAr: "رياضة شورتس"),
        .init(key: "Live", icon: "dot.radiowaves.left.and.right", source: .browse("UC4R8DWoMoI7CAwX8_LjQHig"), shortsEn: "live shorts", shortsAr: "مباشر شورتس"),
        .init(key: "Tech", icon: "cpu", source: .search(en: "tech review", ar: "مراجعة تقنية"), shortsEn: "tech shorts", shortsAr: "تقنية شورتس"),
        .init(key: "Learning", icon: "graduationcap.fill", source: .browse("UCtFRv9O2AHqOZjjynzrv-xg"), shortsEn: "learning shorts", shortsAr: "تعلم شورتس"),
        .init(key: "Fashion & Beauty", icon: "tshirt.fill", source: .browse("UCrpQ4p1Ql_hG8rKXIKM1MOQ"), shortsEn: "fashion beauty shorts", shortsAr: "موضة وجمال شورتس"),
    ]
}

/// YouTube (WEB) calls and their parsers.
nonisolated enum VideoAPI {
    static var api: InnerTube { .shared }

    @concurrent static func search(_ query: String, filter: VideoSearchFilter, sort: VideoSort = .relevance, continuation: String? = nil) async throws -> ([VideoSearchResult], String?) {
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

    /// The shelves of a Home topic. A feed without titled rows (For You, a search) is one untitled shelf.
    @concurrent static func feed(topic: VideoTopic, seeds: [String]) async throws -> [VideoShelf] {
        switch topic.source {
        case .forYou:
            // Related videos of what was watched recently, else the region's Hype leaderboard.
            var videos: [Video] = []
            for seed in seeds.prefix(3) {
                if let details = try? await watch(seed) { videos += details.related }
            }
            if videos.count < 8 {
                do {
                    videos += try await browseShelves(VideoTopic.hypeBrowseId).flatMap(\.videos)
                } catch where videos.isEmpty { throw error }
            }
            var seen = Set<String>()
            return [VideoShelf(id: "for-you", title: nil, videos: videos.filter { seen.insert($0.id).inserted }.shuffled())]
        case .browse(let browseId):
            return try await browseShelves(browseId)
        case .search(let en, let ar):
            let videos = try await search(api.language == "ar" ? ar : en, filter: .videos).0.compactMap { if case .video(let v) = $0 { v } else { nil } }
            return [VideoShelf(id: "search", title: nil, videos: videos)]
        }
    }

    @concurrent static func browseShelves(_ browseId: String) async throws -> [VideoShelf] {
        parseShelves(try await api.web("browse", ["browseId": browseId]))
    }

    /// The rows of an explore page, in order: `richShelfRenderer` (topic channels), `shelfRenderer`
    /// (Hype, channel Home) and `horizontalCardListRenderer` (Gaming). Items outside any row (a plain
    /// grid) form one untitled shelf. Only the selected tab is read, never the header's panels.
    static func parseShelves(_ root: J) -> [VideoShelf] {
        let tabs = root.path("contents.twoColumnBrowseResultsRenderer.tabs").array
        let tab = tabs.first { $0.path("tabRenderer.selected").bool == true } ?? tabs.first
        let tabContent = tab?.path("tabRenderer.content") ?? J(nil)
        let content = tabContent.exists ? tabContent : root["contents"]
        var shelves: [VideoShelf] = []
        var loose = VideoShelf(id: "loose", title: nil)

        func add(_ item: J, key: String, to shelf: inout VideoShelf) -> Bool {
            switch key {
            case "videoRenderer", "gridVideoRenderer", "videoCardRenderer":
                if let v = parseVideoRenderer(item) { shelf.videos.append(v) }
            case "lockupViewModel":
                let type = item["contentType"].string ?? ""
                if type.contains("VIDEO") { if let v = parseLockup(item) { shelf.videos.append(v) } }
                else if type.contains("PLAYLIST") || type.contains("STATION") || type.contains("PODCAST") || type.contains("COURSE") {
                    if let p = parseLockupPlaylist(item) { shelf.playlists.append(p) }
                }
            case "gridPlaylistRenderer", "playlistRenderer":
                if let p = parsePlaylistRenderer(item) { shelf.playlists.append(p) }
            default: return false
            }
            return true
        }

        func walk(_ node: J, into shelf: inout VideoShelf) {
            if node.raw is [Any] {
                for child in node.array { walk(child, into: &shelf) }
                return
            }
            for (key, value) in node.dict {
                if add(value, key: key, to: &shelf) { continue }
                let title: String?
                switch key {
                case "richShelfRenderer", "shelfRenderer": title = value["title"].text
                case "horizontalCardListRenderer": title = value.path("header.richListHeaderRenderer.title").text
                default:
                    // Reels and promo carousels are not videos of the page; their own shelves show Shorts.
                    if key == "reelShelfRenderer" || key == "carouselItemRenderer" { continue }
                    walk(value, into: &shelf)
                    continue
                }
                var row = VideoShelf(id: "\(shelves.count)", title: title?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{202B}\u{202A}\u{202C}"))))
                walk(value, into: &row)
                if !row.isEmpty { shelves.append(row) }
            }
        }
        walk(content, into: &loose)
        if !loose.isEmpty { shelves.insert(loose, at: 0) }
        return shelves.map { shelf in
            var s = shelf
            var seenV = Set<String>(), seenP = Set<String>()
            s.videos = s.videos.filter { seenV.insert($0.id).inserted }
            s.playlists = s.playlists.filter { seenP.insert($0.id).inserted }
            return s
        }
    }

    @concurrent static func suggestions(_ query: String) async -> [String] {
        // `.urlQueryAllowed` leaves `&`, `=` and `+` as they are, so "a&b" or "c++" would break the query.
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?/"))),
              let url = URL(string: "https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&xhr=t&oe=utf-8&hl=\(api.language)&gl=\(api.region)&q=\(q)"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return parseSuggestions(data)
    }

    static func parseSuggestions(_ data: Data) -> [String] {
        let root = J(data: data)
        return root[1].array.compactMap { $0[0].string?.decodingHTMLEntities }
    }

    // MARK: Watch page

    @concurrent static func watch(_ videoId: String) async throws -> WatchDetails {
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
            commentsToken: commentsToken, commentCount: commentCount,
            liveChat: LiveChatSource.parse(watchNext: root))
    }

    /// Shorts comments page through `browse` rather than `next`.
    @concurrent static func comments(token: String, endpoint: String = "next") async throws -> ([Comment], String?) {
        var token = token
        var visited: Set<String> = [token]
        while true {
            let root = try await api.web(endpoint, ["continuation": token])
            let (comments, tokens) = parseComments(root)
            // The first page's real list token; a page that leads back to one already read ends here.
            if comments.isEmpty, let first = tokens.first, visited.insert(first).inserted, visited.count <= 4 {
                token = first
                continue
            }
            return (comments, tokens.last)
        }
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

    /// The channel's header and tab list (its Home tab, without params), then its first content tab:
    /// Videos when it has one. Tab params always come from the response's own tab list.
    @concurrent static func channel(_ channelId: String) async throws -> (ChannelPage, ChannelTab?, ChannelTabPage) {
        let root = try await api.web("browse", ["browseId": channelId])
        let page = parseChannel(root, channelId: channelId)
        guard let tab = page.defaultTab else { return (page, nil, ChannelTabPage(videos: page.videos)) }
        let content = try await channelTab(channelId, tab: tab, name: page.name)
        return (page, tab, content)
    }

    /// One tab of a channel, or its next page with `continuation`.
    @concurrent static func channelTab(_ channelId: String, tab: ChannelTab, name: String, continuation: String? = nil) async throws -> ChannelTabPage {
        let body: [String: Any] = continuation.map { ["continuation": $0] } ?? ["browseId": channelId, "params": tab.params]
        return parseChannelTab(try await api.web("browse", body), channelId: channelId, name: name)
    }

    static func parseChannel(_ root: J, channelId: String) -> ChannelPage {
        let header = root.first("pageHeaderViewModel")
        let name = header["title"].text ?? root.path("metadata.channelMetadataRenderer.title").string ?? ""
        let rows = header["metadata"].findAll("metadataRows").first?.array ?? []
        let parts = rows.flatMap { $0["metadataParts"].array.compactMap { $0["text"]["content"].string } }
        let subscribers = subscriberPart(parts)
        let videoCount = parts.first { p in
            !p.hasPrefix("@") && p != subscribers && p.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        }
        let verified = header["title"].findAll("imageName").contains { ($0.string ?? "").hasPrefix("CHECK_CIRCLE") }
        let tabs = parseChannelTabs(root)
        // The selected tab's items, when the response is already a content tab (Videos, as before).
        let content = parseChannelTab(root, channelId: channelId, name: name)
        return ChannelPage(
            id: channelId, name: name,
            handle: parts.first { $0.hasPrefix("@") },
            avatar: header["image"].bestThumbnail ?? root.path("metadata.channelMetadataRenderer.avatar").bestThumbnail,
            banner: header["banner"].bestThumbnail,
            subscribers: subscribers,
            description: root.path("metadata.channelMetadataRenderer.description").string
                ?? header.path("description.descriptionPreviewViewModel.description").text,
            videos: content.videos,
            videoCount: videoCount,
            isVerified: verified,
            tabs: tabs,
            aboutToken: header["description"].findAll("continuationCommand").first?["token"].string
                ?? header.findAll("continuationCommand").first?["token"].string)
    }

    /// The tabs a channel lists, typed by their URL's last path part (titles are localized).
    static func parseChannelTabs(_ root: J) -> [ChannelTab] {
        root.path("contents.twoColumnBrowseResultsRenderer.tabs").array.compactMap { t -> ChannelTab? in
            let tab = t["tabRenderer"]
            guard let params = tab.path("endpoint.browseEndpoint.params").string else { return nil }
            let url = tab.path("endpoint.commandMetadata.webCommandMetadata.url").string ?? ""
            let kind: ChannelTab.Kind = switch url.split(separator: "/").last.map(String.init) ?? "" {
            case "featured": .home
            case "videos": .videos
            case "shorts": .shorts
            case "streams": .live
            case "playlists": .playlists
            case "podcasts": .podcasts
            default: .other
            }
            return ChannelTab(kind: kind, title: tab["title"].text ?? "", params: params)
        }
    }

    /// The items of the selected tab (or of a continuation page) and the token of its next page.
    static func parseChannelTab(_ root: J, channelId: String, name: String) -> ChannelTabPage {
        let tabs = root.path("contents.twoColumnBrowseResultsRenderer.tabs").array
        let selected = tabs.first { $0.path("tabRenderer.selected").bool == true }?.path("tabRenderer.content")
        let actions = root["onResponseReceivedActions"]
        let scope = actions.exists ? actions : (selected ?? J(nil))
        var videos = scope.findAll("lockupViewModel").filter { ($0["contentType"].string ?? "VIDEO").contains("VIDEO") }.compactMap(parseLockup)
            + scope.findAll("videoRenderer").compactMap(parseVideoRenderer)
            + scope.findAll("gridVideoRenderer").compactMap(parseVideoRenderer)
        var seen = Set<String>()
        videos = videos.filter { seen.insert($0.id).inserted }
            .map { var v = $0; if v.channel.isEmpty { v.channel = name }; v.channelId = v.channelId ?? channelId; return v }
        let playlists = scope.findAll("lockupViewModel").filter {
            let type = $0["contentType"].string ?? ""
            return type.contains("PLAYLIST") || type.contains("PODCAST") || type.contains("COURSE")
        }.compactMap(parseLockupPlaylist) + scope.findAll("gridPlaylistRenderer").compactMap(parsePlaylistRenderer)
        var seenP = Set<String>()
        return ChannelTabPage(
            videos: videos,
            playlists: playlists.filter { seenP.insert($0.id).inserted },
            continuation: scope.findAll("continuationItemRenderer").last?.findAll("token").first?.string)
    }

    @concurrent static func channelAbout(token: String) async throws -> ChannelAbout {
        parseAbout(try await api.web("browse", ["continuation": token]))
    }

    static func parseAbout(_ root: J) -> ChannelAbout {
        let a = root.first("aboutChannelViewModel")
        let links = a["links"].array.compactMap { l -> ChannelLink? in
            let link = l["channelExternalLinkViewModel"]
            let display = link["link"].text ?? ""
            // The link's own target; the view model's favicon sources carry image URLs too.
            let redirect = link["link"].findAll("urlEndpoint").first?["url"].string
            guard let url = redirect.flatMap(Self.unwrapRedirect) ?? URL(string: display.hasPrefix("http") ? display : "https://" + display),
                  !display.isEmpty else { return nil }
            return ChannelLink(title: link["title"].text ?? display, display: display, url: url)
        }
        func plain(_ s: String?) -> String? { s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        return ChannelAbout(
            description: plain(a["description"].text),
            links: links,
            joined: plain(a["joinedDateText"].text),
            views: plain(a["viewCountText"].text),
            country: plain(a["country"].text),
            subscribers: plain(a["subscriberCountText"].text),
            videos: plain(a["videoCountText"].text),
            url: plain(a["displayCanonicalChannelUrl"].text))
    }

    /// The target of a `youtube.com/redirect?...&q=<url>` link.
    static func unwrapRedirect(_ s: String) -> URL? {
        guard let comps = URLComponents(string: s) else { return nil }
        if comps.path == "/redirect", let q = comps.queryItems?.first(where: { $0.name == "q" })?.value {
            return URL(string: q.hasPrefix("http") ? q : "https://" + q)
        }
        return comps.scheme == "https" || comps.scheme == "http" ? comps.url : nil
    }

    /// The subscriber count among a channel header's metadata parts, in whatever language YouTube answered:
    /// a part that names subscribers, else the first part with digits after the handle that is not the video count
    /// (the header lists the handle, then subscribers, then videos).
    static func subscriberPart(_ parts: [String]) -> String? {
        let words = ["subscriber", "مشترك"]
        if let named = parts.first(where: { p in words.contains { p.localizedCaseInsensitiveContains($0) } }) { return named }
        let videoWords = ["video", "فيديو"]
        return parts.first { p in
            !p.hasPrefix("@") && p.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
                && !videoWords.contains { p.localizedCaseInsensitiveContains($0) }
        }
    }

    /// Public RSS feed of a channel: the subscriptions feed for local follows, without an account.
    @concurrent static func rssFeed(channelId: String) async -> [Video] {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return ChannelFeedParser.parse(data)
    }

    @concurrent static func playlist(_ playlistId: String) async throws -> (String, [Video]) {
        let id = playlistId.hasPrefix("VL") ? playlistId : "VL" + playlistId
        let root = try await api.web("browse", ["browseId": id])
        let title = root.path("metadata.playlistMetadataRenderer.title").string ?? root.first("pageHeaderViewModel")["title"].text ?? String(localized: "Playlist")
        var seen = Set<String>()
        return (title, parsePlaylistVideos(root).filter { seen.insert($0.id).inserted })
    }

    /// A playlist page's videos: `lockupViewModel`s since late 2026 (`playlistVideoRenderer` before).
    static func parsePlaylistVideos(_ root: J) -> [Video] {
        let tabs = root.path("contents.twoColumnBrowseResultsRenderer.tabs")
        let scope = tabs.exists ? tabs : root
        return scope.findAll("playlistVideoRenderer").compactMap(parseVideoRenderer)
            + scope.findAll("lockupViewModel").filter { ($0["contentType"].string ?? "").contains("VIDEO") }.compactMap(parseLockup)
    }

    // MARK: Parsers

    /// `videoRenderer`, `compactVideoRenderer`, `playlistVideoRenderer`, `gridVideoRenderer` (Hype) and
    /// `videoCardRenderer` (the Gaming topic, with views and date in one `metadataText`).
    static func parseVideoRenderer(_ v: J) -> Video? {
        guard let id = v["videoId"].string else { return nil }
        let owner = v["ownerText"].exists ? v["ownerText"]
            : v["longBylineText"].exists ? v["longBylineText"]
            : v["shortBylineText"].exists ? v["shortBylineText"] : v["bylineText"]
        let isLive = v["badges"].findAll("style").contains { $0.string == "BADGE_STYLE_TYPE_LIVE_NOW" }
            || v["thumbnailOverlays"].findAll("style").contains { $0.string == "LIVE" }
        let overlayDuration = v["thumbnailOverlays"].array.lazy
            .compactMap { $0.path("thumbnailOverlayTimeStatusRenderer.text").text }
            .first { $0.contains(":") }
        // "88 million views · 1 month ago"
        let cardParts = (v["metadataText"].text ?? "").components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Video(
            id: id,
            title: v["title"].text ?? "",
            channel: owner.text ?? "",
            channelId: owner.runs.first?.path("navigationEndpoint.browseEndpoint.browseId").string,
            channelAvatar: v["channelThumbnailSupportedRenderers"].bestThumbnail ?? v["channelThumbnail"].bestThumbnail,
            thumbnail: v["thumbnail"].bestThumbnail,
            durationText: v["lengthText"].text ?? overlayDuration,
            views: v["shortViewCountText"].text ?? v["viewCountText"].text ?? v["videoInfo"].text ?? cardParts.first,
            published: v["publishedTimeText"].text ?? (cardParts.count > 1 ? cardParts[1] : nil),
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
        // Skip the "View full playlist" link, which opens the playlist itself.
        let first = rows.flatMap { $0["metadataParts"].array }.first { part in
            !(part.findAll("browseId").first?.string ?? "").hasPrefix("VL")
        }?["text"]["content"].string
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
