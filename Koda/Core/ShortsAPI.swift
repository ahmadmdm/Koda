import Foundation

/// One Short as a shelf or the reel sequence lists it. Most sequence entries carry only an id and
/// a portrait frame; the rest comes from `ShortsAPI.details` when the Short is shown.
nonisolated struct ShortItem: Hashable, Identifiable, Sendable {
    var id: String
    var title: String = ""
    var views: String?
    var thumbnail: String?
    /// The `reelWatchEndpoint.sequenceParams` that continues the feed after this Short.
    var sequenceParams: String?

    var thumbnailURL: URL? { URL(string: thumbnail ?? "https://i.ytimg.com/vi/\(id)/frame0.jpg") }
    var shareURL: URL { URL(string: "https://www.youtube.com/shorts/\(id)")! }
}

/// What the Shorts overlay shows: title, channel, counts and the comments entry point.
nonisolated struct ShortDetails: Sendable {
    var title: String
    var channel: ChannelSummary?
    var views: String?
    var published: String?
    var likes: String?
    var commentsToken: String?
    var commentCount: String?
}

nonisolated struct ShortsPage: Sendable {
    var items: [ShortItem]
    var continuation: String?
}

/// The WEB reel endpoints, as Koda for Android uses them (`ShortsResponses.kt`):
/// `reel/reel_item_watch` for a seedless start or one Short's metadata, and
/// `reel/reel_watch_sequence` for the swipe feed. Verified signed out, November 2026.
nonisolated enum ShortsAPI {
    static var api: InnerTube { .shared }

    /// Shorts lockups of a search, for a shelf.
    @concurrent static func search(_ query: String) async throws -> [ShortItem] {
        lockups(in: try await api.web("search", ["query": query]))
    }

    /// A channel's Shorts tab.
    @concurrent static func channel(_ channelId: String) async throws -> [ShortItem] {
        lockups(in: try await api.web("browse", ["browseId": channelId, "params": "EgZzaG9ydHPyBgUKA5oBAA%3D%3D"]))
    }

    /// YouTube's own "Shorts" tab start: one Short plus the token of the sequence after it.
    @concurrent static func seedless() async throws -> ShortsPage {
        let root = try await api.web("reel/reel_item_watch", [
            "params": "CA8%3D", "inputType": "REEL_WATCH_INPUT_TYPE_SEEDLESS", "disablePlayerResponse": true,
        ])
        guard root["status"].string == "REEL_ITEM_WATCH_STATUS_SUCCEEDED",
              var item = endpoint(root.path("replacementEndpoint.reelWatchEndpoint")) else { throw InnerTubeError.empty }
        let header = root.first("videoDescriptionHeaderRenderer")
        item.title = header["title"].text ?? ""
        item.views = header["views"].text
        return ShortsPage(items: [item], continuation: root["sequenceContinuation"].string)
    }

    /// The next page of the swipe feed. Seed params and continuation tokens go in the same field.
    @concurrent static func sequence(_ params: String) async throws -> ShortsPage {
        let root = try await api.web("reel/reel_watch_sequence", ["sequenceParams": params])
        var seen = Set<String>()
        // Only top-level entries belong to the page; nested endpoints are unrelated UI actions.
        let items = root["entries"].array.compactMap { endpoint($0.path("command.reelWatchEndpoint")) }
            .filter { seen.insert($0.id).inserted }
        return ShortsPage(items: items, continuation: root.path("continuationEndpoint.continuationCommand.token").string)
    }

    @concurrent static func details(_ videoId: String) async throws -> ShortDetails {
        let root = try await api.web("reel/reel_item_watch", ["playerRequest": ["videoId": videoId], "disablePlayerResponse": true])
        let header = root.first("videoDescriptionHeaderRenderer")
        let channelId = header.path("channelNavigationEndpoint.browseEndpoint.browseId").string
        let channelName = header["channel"].text ?? ""
        let like = root.first("likeButtonViewModel").first("defaultButtonViewModel").path("buttonViewModel.title").string
        let factoidLikes = header["factoid"].array.first { ($0.path("factoidRenderer.label").text ?? "").localizedCaseInsensitiveContains("like") }?
            .path("factoidRenderer.value").text
        let comments = root["engagementPanels"].array.map { $0["engagementPanelSectionListRenderer"] }
            .first { $0["targetId"].string == "engagement-panel-comments-section" }
        return ShortDetails(
            title: header["title"].text ?? "",
            channel: channelId.map { ChannelSummary(id: $0, name: channelName, avatar: header["channelThumbnail"].bestThumbnail) },
            views: header["views"].text,
            published: header["publishDate"].text,
            likes: like ?? factoidLikes,
            commentsToken: comments?["content"].findAll("continuationCommand").first?["token"].string,
            commentCount: comments?.path("header.engagementPanelTitleHeaderRenderer.contextualInfo").text)
    }

    // MARK: Parsers

    /// Every Short in a response, deduped, in shelf order: `shortsLockupViewModel` (current WEB)
    /// and `reelItemRenderer` (older shelves).
    static func lockups(in root: J) -> [ShortItem] {
        var seen = Set<String>()
        let modern = root.findAll("shortsLockupViewModel").compactMap { l -> ShortItem? in
            guard var item = endpoint(l.path("onTap.innertubeCommand.reelWatchEndpoint")) else { return nil }
            item.title = l.path("overlayMetadata.primaryText.content").string ?? ""
            item.views = l.path("overlayMetadata.secondaryText.content").string
            item.thumbnail = l["thumbnailViewModel"].bestThumbnail ?? item.thumbnail
            return item
        }
        let legacy = root.findAll("reelItemRenderer").compactMap { r -> ShortItem? in
            guard let id = r["videoId"].string else { return nil }
            return ShortItem(id: id, title: r["headline"].text ?? "", views: r["viewCountText"].text,
                             thumbnail: r["thumbnail"].bestThumbnail,
                             sequenceParams: r.path("navigationEndpoint.reelWatchEndpoint.sequenceParams").string)
        }
        return (modern + legacy).filter { seen.insert($0.id).inserted }
    }

    static func endpoint(_ reel: J) -> ShortItem? {
        guard let id = reel["videoId"].string, id.count == 11 else { return nil }
        // Some entries prefetch the WEB player response; its metadata is usable, its stream URLs are not.
        let details = reel.path("unserializedPrefetchData.playerResponse.videoDetails")
        let prefetched = details["videoId"].string == id
        return ShortItem(id: id, title: prefetched ? details["title"].string ?? "" : "",
                         thumbnail: reel["thumbnail"]["thumbnails"][0]["url"].string,
                         sequenceParams: reel["sequenceParams"].string)
    }
}
