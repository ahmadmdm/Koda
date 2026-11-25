import Foundation

/// Where a video's chat starts: `next` → `conversationBar.liveChatRenderer`. A finished broadcast
/// that kept its chat exposes the replay under the same key, with `isReplay`.
nonisolated struct LiveChatSource: Hashable, Sendable {
    var continuation: String
    var isReplay: Bool

    static func parse(watchNext root: J) -> LiveChatSource? {
        let renderer = root.path("contents.twoColumnWatchNextResults.conversationBar.liveChatRenderer")
        guard let token = renderer.path("continuations.0.reloadContinuationData.continuation").string else { return nil }
        return LiveChatSource(continuation: token, isReplay: renderer["isReplay"].bool == true)
    }
}

nonisolated struct LiveChatMessage: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case text, superChat, membership, system }
    enum Role: Hashable, Sendable { case viewer, member, moderator, owner }

    var id: String
    var kind: Kind
    var author: String
    var authorPhoto: String?
    var role: Role = .viewer
    var text: String
    /// Super Chat amount ("$5.00") or a membership headline.
    var amount: String?
    /// Super Chat tier colours, ARGB.
    var headerColor: UInt32?
    var bodyColor: UInt32?
    /// Position in the video, for chat replay.
    var offsetMs: Int?
}

nonisolated struct LiveChatPage: Sendable {
    var messages: [LiveChatMessage]
    var removedIds: Set<String>
    var next: String?
    /// Replay only: the token that restarts the replay at a new player position.
    var seek: String?
    var timeoutMs: Int
}

/// `live_chat/get_live_chat` and `live_chat/get_live_chat_replay` on WEB, as Koda for Android
/// reads them (`LiveChat.kt`, `LiveChatParsers.kt`). Verified against a live stream and a
/// finished one, November 2026. Reading chat needs no account.
nonisolated enum LiveChatAPI {
    static func live(_ continuation: String) async throws -> LiveChatPage {
        parse(try await InnerTube.shared.web("live_chat/get_live_chat", ["continuation": continuation]))
    }

    /// One replay window (a few minutes of chat) starting near `offsetMs`.
    static func replay(_ continuation: String, offsetMs: Int) async throws -> LiveChatPage {
        parse(try await InnerTube.shared.web("live_chat/get_live_chat_replay", [
            "continuation": continuation, "currentPlayerState": ["playerOffsetMs": String(max(0, offsetMs))],
        ]))
    }

    static func parse(_ root: J) -> LiveChatPage {
        let chat = root.path("continuationContents.liveChatContinuation")
        var messages: [LiveChatMessage] = []
        var removed = Set<String>()

        func handle(_ action: J, offset: Int?) {
            if var m = parseItem(action.path("addChatItemAction.item")) { m.offsetMs = offset; messages.append(m) }
            for key in ["removeChatItemAction", "markChatItemAsDeletedAction"] {
                if let id = action[key]["targetItemId"].string { removed.insert(id) }
            }
        }
        for action in chat["actions"].array {
            let replay = action["replayChatItemAction"]
            if replay.exists {
                let offset = replay["videoOffsetTimeMsec"].int
                for inner in replay["actions"].array { handle(inner, offset: offset) }
            } else {
                handle(action, offset: nil)
            }
        }

        var next: String?, seek: String?, timeout = 10_000
        for c in chat["continuations"].array {
            for key in ["invalidationContinuationData", "timedContinuationData", "reloadContinuationData", "liveChatReplayContinuationData"] {
                let data = c[key]
                if next == nil, let token = data["continuation"].string {
                    next = token
                    timeout = data["timeoutMs"].int ?? data["timeUntilLastMessageMsec"].int ?? timeout
                }
            }
            if let token = c.path("playerSeekContinuationData.continuation").string { seek = token }
        }
        return LiveChatPage(messages: messages, removedIds: removed, next: next, seek: seek, timeoutMs: timeout)
    }

    static func parseItem(_ item: J) -> LiveChatMessage? {
        if let r = renderer(item, "liveChatTextMessageRenderer"), let id = r["id"].string {
            return LiveChatMessage(id: id, kind: .text, author: r["authorName"].text ?? "", authorPhoto: r["authorPhoto"].bestThumbnail,
                                   role: role(r), text: messageText(r["message"]))
        }
        if let r = renderer(item, "liveChatPaidMessageRenderer"), let id = r["id"].string {
            return LiveChatMessage(id: id, kind: .superChat, author: r["authorName"].text ?? "", authorPhoto: r["authorPhoto"].bestThumbnail,
                                   role: role(r), text: messageText(r["message"]), amount: r["purchaseAmountText"].text,
                                   headerColor: argb(r["headerBackgroundColor"]), bodyColor: argb(r["bodyBackgroundColor"]))
        }
        if let r = renderer(item, "liveChatPaidStickerRenderer"), let id = r["id"].string {
            let color = argb(r["backgroundColor"])
            return LiveChatMessage(id: id, kind: .superChat, author: r["authorName"].text ?? "", authorPhoto: r["authorPhoto"].bestThumbnail,
                                   role: role(r), text: r.path("sticker.accessibility.accessibilityData.label").string ?? "",
                                   amount: r["purchaseAmountText"].text, headerColor: color, bodyColor: color)
        }
        if let r = renderer(item, "liveChatMembershipItemRenderer"), let id = r["id"].string {
            return LiveChatMessage(id: id, kind: .membership, author: r["authorName"].text ?? "", authorPhoto: r["authorPhoto"].bestThumbnail,
                                   role: .member, text: messageText(r["message"]),
                                   amount: r["headerPrimaryText"].text ?? r["headerSubtext"].text)
        }
        if let r = renderer(item, "liveChatViewerEngagementMessageRenderer"), let id = r["id"].string {
            return LiveChatMessage(id: id, kind: .system, author: "", text: messageText(r["message"]))
        }
        return nil
    }

    private static func renderer(_ item: J, _ key: String) -> J? {
        let r = item[key]
        return r.exists ? r : nil
    }

    /// Text and emoji runs as plain text: a unicode emoji's id is the character itself, a channel
    /// emoji has an opaque id and is shown by its `:shortcut:`.
    static func messageText(_ message: J) -> String {
        if let simple = message["simpleText"].string { return simple }
        return message.runs.map { run -> String in
            if let text = run["text"].string { return text }
            let emoji = run["emoji"]
            let id = emoji["emojiId"].string ?? ""
            if emoji["isCustomEmoji"].bool != true, !id.isEmpty, id.unicodeScalars.count <= 8, !id.contains("/") { return id }
            return emoji["shortcuts"][0].string ?? emoji.path("image.accessibility.accessibilityData.label").string ?? ""
        }.joined()
    }

    private static func role(_ r: J) -> LiveChatMessage.Role {
        var result = LiveChatMessage.Role.viewer
        for badge in r["authorBadges"].array.map({ $0["liveChatAuthorBadgeRenderer"] }) {
            switch badge.path("icon.iconType").string {
            case "OWNER": return .owner
            case "MODERATOR": result = .moderator
            default: if badge["customThumbnail"].exists, result == .viewer { result = .member }
            }
        }
        return result
    }

    private static func argb(_ value: J) -> UInt32? {
        guard let n = value.double, n >= 0, n <= Double(UInt32.max) else { return nil }
        return UInt32(n)
    }
}
