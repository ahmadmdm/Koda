import Foundation
import Testing
@testable import Koda

@Suite struct WatchProgressTests {
    private func entry(_ id: String, title: String = "A video", position: Double, duration: Double? = nil,
                       durationText: String? = nil, minutesAgo: Double = 0, live: Bool = false) -> VideoEntry {
        VideoEntry(video: Video(id: id, title: title, channel: "Channel", durationText: durationText, isLive: live),
                   date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), position: position, duration: duration)
    }

    @Test func resumesOnlyBetweenTheStartAndTheEnd() {
        #expect(WatchProgress.resumePosition(saved: 0, duration: 600) == nil)
        #expect(WatchProgress.resumePosition(saved: 8, duration: 600) == nil)
        #expect(WatchProgress.resumePosition(saved: 125, duration: 600) == 125)
        // The last 20 seconds, or the last 5 %, count as watched.
        #expect(WatchProgress.resumePosition(saved: 585, duration: 600) == nil)
        #expect(WatchProgress.resumePosition(saved: 3500, duration: 3600) == nil)
        #expect(WatchProgress.resumePosition(saved: 3300, duration: 3600) == 3300)
        // A downloaded file or a link whose length is not known yet still resumes.
        #expect(WatchProgress.resumePosition(saved: 125, duration: 0) == 125)
        #expect(WatchProgress.resumePosition(saved: .nan, duration: 600) == nil)
    }

    @Test func continueWatchingShowsVideosInProgressNewestFirst() {
        let history = [
            entry("old", position: 200, duration: 600, minutesAgo: 60),
            entry("new", position: 45, durationText: "10:00", minutesAgo: 1),
            entry("barely", position: 5, duration: 600),
            entry("done", position: 590, duration: 600),
            entry("untitled", title: "  ", position: 200, duration: 600),
            entry("live", position: 200, live: true),
            entry("unknownLength", position: 30, minutesAgo: 30),
        ]
        #expect(WatchProgress.continueWatching(history).map(\.id) == ["new", "unknownLength", "old"])
        #expect(WatchProgress.fraction(of: history[0]) == 200.0 / 600)
        #expect(WatchProgress.fraction(of: history[1]) == 45.0 / 600)
        #expect(WatchProgress.fraction(of: history[6]) == nil)
    }

    @Test func writesLengthsTheWayYouTubeDoes() {
        #expect(WatchProgress.durationText(65) == "1:05")
        #expect(WatchProgress.durationText(3723) == "1:02:03")
        #expect(WatchProgress.durationText(0) == nil)
    }

    @Test func reopeningAVideoKeepsWhatTheHistoryKnew() {
        let old = Video(id: "x", title: "Real title", channel: "Real channel", channelId: "UC1", thumbnail: "t", durationText: "4:00")
        let link = Video(id: "x", title: "", channel: "")
        let merged = LibraryStore.merged(link, keeping: old)
        #expect(merged.title == "Real title")
        #expect(merged.channel == "Real channel")
        #expect(merged.channelId == "UC1")
        #expect(merged.durationText == "4:00")
        var renamed = link; renamed.title = "New"
        #expect(LibraryStore.merged(renamed, keeping: old).title == "New")
    }

    @Test func readsLibrariesFromBeforeLengthsAndAccounts() throws {
        let json = """
        {"likedSongs":[],"playlists":[],"plays":[],"savedCollections":[],"followedArtists":[],"musicSearches":[],
         "videoSearches":[],"videoHistory":[{"video":{"id":"a","title":"T","channel":"C","isLive":false},"date":0,"position":42}],
         "watchLater":[],"likedVideos":[],"subscriptions":[{"id":"UC1","name":"One"}],"hiddenChannels":[],"hiddenVideos":[],
         "downloads":[],"tasteArtists":[]}
        """
        let data = try JSONDecoder().decode(LibraryData.self, from: Data(json.utf8))
        #expect(data.videoHistory.first?.position == 42)
        #expect(data.videoHistory.first?.duration == nil)
        #expect(data.subscriptions.first?.isDeviceFollow == true)
        // And the new fields are written only when set.
        let encoded = String(decoding: try JSONEncoder().encode(data.subscriptions), as: UTF8.self)
        #expect(!encoded.contains("accounts"))
    }
}

@Suite struct FollowedChannelsTests {
    private func channel(_ id: String) -> ChannelSummary { ChannelSummary(id: id, name: id) }

    @Test func showsDeviceFollowsAndTheActiveAccountsChannels() {
        var all = FollowedChannels.subscribing(channel("device"), account: nil, into: [])
        all = FollowedChannels.importing([channel("a1"), channel("both")], for: "A", complete: true, into: all)
        all = FollowedChannels.importing([channel("b1"), channel("both")], for: "B", complete: true, into: all)
        #expect(Set(FollowedChannels.visible(all, account: nil).map(\.id)) == ["device"])
        #expect(Set(FollowedChannels.visible(all, account: "A").map(\.id)) == ["device", "a1", "both"])
        #expect(Set(FollowedChannels.visible(all, account: "B").map(\.id)) == ["device", "b1", "both"])
    }

    @Test func olderFollowsTheAccountHasBecomeTheAccounts() {
        // Before channels were tagged, A's import mixed into the device's list.
        let legacy = [channel("mine"), channel("fromA"), channel("fromB")]
        var all = FollowedChannels.importing([channel("fromA")], for: "A", complete: true, into: legacy)
        all = FollowedChannels.importing([channel("fromB")], for: "B", complete: true, into: all)
        #expect(FollowedChannels.visible(all, account: "A").map(\.id) == ["mine", "fromA"])
        #expect(FollowedChannels.visible(all, account: "B").map(\.id) == ["mine", "fromB"])
        #expect(FollowedChannels.visible(all, account: nil).map(\.id) == ["mine"])
    }

    @Test func aCompleteListDropsChannelsTheAccountLeft() {
        var all = FollowedChannels.importing([channel("a1"), channel("a2")], for: "A", complete: true, into: [])
        let partial = FollowedChannels.importing([channel("a1")], for: "A", complete: false, into: all)
        #expect(partial.map(\.id) == ["a1", "a2"])
        all = FollowedChannels.importing([channel("a1")], for: "A", complete: true, into: all)
        #expect(all.map(\.id) == ["a1"])
    }

    @Test func unsubscribingLeavesOtherAccountsAlone() {
        var all = FollowedChannels.importing([channel("both")], for: "A", complete: true, into: [])
        all = FollowedChannels.importing([channel("both")], for: "B", complete: true, into: all)
        all = FollowedChannels.unsubscribing("both", account: "A", from: all)
        #expect(FollowedChannels.visible(all, account: "A").isEmpty)
        #expect(FollowedChannels.visible(all, account: "B").map(\.id) == ["both"])
        all = FollowedChannels.unsubscribing("both", account: "B", from: all)
        #expect(all.isEmpty)

        var device = FollowedChannels.subscribing(channel("d"), account: nil, into: [])
        device = FollowedChannels.unsubscribing("d", account: nil, from: device)
        #expect(device.isEmpty)
    }

    @Test func subscribingWhileSignedInFollowsOnTheAccount() {
        let all = FollowedChannels.subscribing(channel("c"), account: "A", into: [])
        #expect(FollowedChannels.visible(all, account: "A").map(\.id) == ["c"])
        #expect(FollowedChannels.visible(all, account: "B").isEmpty)
        #expect(FollowedChannels.visible(all, account: nil).isEmpty)
    }

    @Test func signingOutForgetsTheAccountsChannels() {
        var all = FollowedChannels.subscribing(channel("device"), account: nil, into: [])
        all = FollowedChannels.importing([channel("a1"), channel("device")], for: "A", complete: true, into: all)
        all = FollowedChannels.forgetting(accounts: ["A"], in: all)
        #expect(all.map(\.id) == ["device"])
        #expect(all.first?.isDeviceFollow == true)
    }
}

@Suite struct PublishedDateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    /// Seconds before `now`.
    private func ago(_ text: String) -> Int? {
        PublishedDate.parse(text, now: now, calendar: calendar).map { Int(now.timeIntervalSince($0).rounded()) }
    }

    @Test func readsEnglish() {
        #expect(ago("3 hours ago") == 3 * 3600)
        #expect(ago("Streamed 2 days ago") == 2 * 86400)
        #expect(ago("1 week ago") == 7 * 86400)
        #expect(ago("an hour ago") == 3600)
        #expect(ago("5 minutes ago") == 300)
        #expect(ago("2 years ago").map { $0 > 700 * 86400 } == true)
        #expect(ago("Scheduled for 12/25/26") == nil)
        #expect(ago("") == nil)
    }

    @Test func readsArabic() {
        #expect(ago("قبل ٣ ساعات") == 3 * 3600)
        #expect(ago("قبل ساعة واحدة") == 3600)
        #expect(ago("قبل ساعتين") == 2 * 3600)
        #expect(ago("قبل يومين") == 2 * 86400)
        #expect(ago("منذ ٥ أيام") == 5 * 86400)
        #expect(ago("قبل ١٥ يومًا") == 15 * 86400)
        #expect(ago("قبل أسبوعين") == 14 * 86400)
        #expect(ago("تم البث قبل ٣ أسابيع") == 21 * 86400)
        #expect(ago("قبل ١٠ دقائق") == 600)
        #expect(ago("قبل شهرين").map { $0 > 58 * 86400 && $0 < 63 * 86400 } == true)
        #expect(ago("قبل سنة واحدة").map { $0 > 364 * 86400 } == true)
        #expect(ago("قبل 4 ساعات") == 4 * 3600)
    }

    @MainActor @Test func filtersTheFeedByAge() {
        let videos = [Video(id: "today", title: "", channel: ""), Video(id: "lastWeek", title: "", channel: ""),
                      Video(id: "unknown", title: "", channel: "")]
        let dates = ["today": now.addingTimeInterval(-3 * 3600), "lastWeek": now.addingTimeInterval(-9 * 86400)]
        #expect(SubscriptionsView.filter(videos, channel: nil, maxAgeDays: 0, dates: dates, now: now).count == 3)
        #expect(SubscriptionsView.filter(videos, channel: nil, maxAgeDays: 1, dates: dates, now: now).map(\.id) == ["today"])
        #expect(SubscriptionsView.filter(videos, channel: nil, maxAgeDays: 30, dates: dates, now: now).map(\.id) == ["today", "lastWeek"])
    }
}

@Suite struct MediaExportNameTests {
    @Test func namesFilesAfterTheTitle() {
        #expect(MediaExporter.fileName("AC/DC: Back in Black?", fallback: "Video", ext: "mp4") == "AC DC Back in Black.mp4")
        #expect(MediaExporter.fileName("  ", fallback: "Video", ext: "mp4") == "Video.mp4")
        #expect(MediaExporter.fileName(".hidden", fallback: "Song", ext: "m4a") == "hidden.m4a")
        #expect(MediaExporter.fileName("أغنية جميلة", fallback: "Song", ext: "m4a") == "أغنية جميلة.m4a")
        #expect(MediaExporter.fileName(String(repeating: "a", count: 300), fallback: "Video", ext: "mp4").count == 124)
    }
}
