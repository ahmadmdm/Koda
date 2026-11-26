import Foundation

/// Which followed channels belong to whom. The library keeps one list: the device's own follows
/// and the channels each signed-in account subscribes to, tagged with that account. Subscriptions
/// shows the device's follows and the active account's channels only.
nonisolated enum FollowedChannels {
    /// The follows shown while `account` (nil: signed out) is active, in the library's order.
    static func visible(_ all: [ChannelSummary], account: String?) -> [ChannelSummary] {
        all.filter { $0.isFollowed(by: account) }
    }

    /// Takes in the channels `account` subscribes to. When `complete` (every page arrived), a
    /// channel the account no longer subscribes to loses its tag, and goes if nothing else keeps it.
    /// A follow from before accounts were told apart that the account has counts as the account's.
    static func importing(_ channels: [ChannelSummary], for account: String, complete: Bool,
                          into all: [ChannelSummary]) -> [ChannelSummary] {
        let fetched = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var known = Set<String>()
        var result: [ChannelSummary] = all.compactMap { existing in
            var c = existing
            known.insert(c.id)
            var tags = c.accounts ?? []
            if let f = fetched[c.id] {
                if c.onDevice == nil, c.accounts == nil { c.onDevice = false }
                if !tags.contains(account) { tags.append(account) }
                c.accounts = tags
                if c.avatar == nil { c.avatar = f.avatar }
                if c.name.isEmpty { c.name = f.name }
            } else if complete, tags.contains(account) {
                tags.removeAll { $0 == account }
                c.accounts = tags
                if tags.isEmpty, c.onDevice != true { return nil }
            }
            return c
        }
        var seen = known
        for c in channels where seen.insert(c.id).inserted {
            var new = c
            new.accounts = [account]
            new.onDevice = false
            result.append(new)
        }
        return result
    }

    /// Follows a channel: on the active account when signed in, else on the device.
    static func subscribing(_ channel: ChannelSummary, account: String?, into all: [ChannelSummary]) -> [ChannelSummary] {
        var result = all
        if let i = result.firstIndex(where: { $0.id == channel.id }) {
            var c = result[i]
            if let account {
                var tags = c.accounts ?? []
                if !tags.contains(account) { tags.append(account) }
                // An older follow becomes this account's, without losing its place on the device.
                if c.onDevice == nil { c.onDevice = c.isDeviceFollow }
                c.accounts = tags
            } else {
                c.onDevice = true
            }
            result.remove(at: i)
            result.insert(c, at: 0)
        } else {
            var c = channel
            c.accounts = account.map { [$0] } ?? []
            c.onDevice = account == nil
            result.insert(c, at: 0)
        }
        return result
    }

    /// Unfollows a channel as far as the viewer can see it: from the device and the active
    /// account. Another account's subscription stays, out of sight until that account is active.
    static func unsubscribing(_ channelId: String, account: String?, from all: [ChannelSummary]) -> [ChannelSummary] {
        all.compactMap { existing in
            guard existing.id == channelId else { return existing }
            var c = existing
            var tags = c.accounts ?? []
            if let account { tags.removeAll { $0 == account } }
            c.accounts = tags
            c.onDevice = false
            return tags.isEmpty ? nil : c
        }
    }

    /// Accounts signed out of: their channels go, unless the device or another account keeps them.
    static func forgetting(accounts removed: Set<String>, in all: [ChannelSummary]) -> [ChannelSummary] {
        all.compactMap { existing in
            guard let tags = existing.accounts, tags.contains(where: removed.contains) else { return existing }
            var c = existing
            c.accounts = tags.filter { !removed.contains($0) }
            return c.accounts!.isEmpty && c.onDevice != true ? nil : c
        }
    }
}
