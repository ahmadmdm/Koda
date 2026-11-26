import Foundation
import Testing
@testable import Koda

/// Explore topics, channel pages and playlists, from responses captured signed out with hl=ar, gl=SA
/// (November 2026) and reduced (tracking fields dropped, lists cut short).
@Suite struct VideoExploreParsingTests {
    @Test func parsesHypeLeaderboardShelves() throws {
        let shelves = VideoAPI.parseShelves(try Fixture.json("video_topic_hype_ar"))
        #expect(shelves.count >= 4)
        #expect(shelves.allSatisfy { $0.title?.isEmpty == false })
        #expect(Set(shelves.map(\.id)).count == shelves.count)
        let videos = shelves.flatMap(\.videos)
        #expect(videos.count >= 20)
        #expect(videos.allSatisfy { $0.id.count == 11 && !$0.title.isEmpty && !$0.channel.isEmpty })
        #expect(videos.filter { $0.channelId?.hasPrefix("UC") == true }.count >= videos.count * 8 / 10)
        #expect(videos.filter { $0.durationText?.durationSeconds != nil }.count >= videos.count * 8 / 10)
        // Region-appropriate: Arabic shelf titles for hl=ar.
        #expect(shelves.contains { $0.title!.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } })
    }

    @Test func parsesGamingVideoCards() throws {
        let shelves = VideoAPI.parseShelves(try Fixture.json("video_topic_gaming_ar"))
        #expect(shelves.count >= 2)
        let videos = shelves.flatMap(\.videos)
        #expect(videos.count >= 10)
        #expect(videos.allSatisfy { !$0.title.isEmpty && !$0.channel.isEmpty })
        // videoCardRenderer: views and date come from one "views · date" line.
        #expect(videos.filter { $0.views != nil && $0.published != nil }.count >= videos.count / 2)
        #expect(!videos.contains { ($0.views ?? "").contains("·") })
    }

    @Test func parsesMusicTopicStationsAndVideos() throws {
        let shelves = VideoAPI.parseShelves(try Fixture.json("video_topic_music_ar"))
        let playlists = shelves.flatMap(\.playlists)
        #expect(playlists.count >= 10)
        #expect(playlists.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty && $0.thumbnail?.hasPrefix("https://") == true })
        #expect(shelves.flatMap(\.videos).count >= 5)
        #expect(shelves.allSatisfy { $0.title?.isEmpty == false })
    }

    @Test func parsesNewsTopicInArabic() throws {
        let shelves = VideoAPI.parseShelves(try Fixture.json("video_topic_news_ar"))
        let videos = shelves.flatMap(\.videos)
        #expect(shelves.count >= 2)
        #expect(videos.count >= 10)
        #expect(videos.filter { $0.views != nil && $0.channelAvatar != nil }.count >= videos.count * 8 / 10)
        #expect(videos.contains { $0.title.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } })
    }
}

@Suite struct ChannelPageParsingTests {
    @Test func parsesHeaderAndTabs() throws {
        let page = VideoAPI.parseChannel(try Fixture.json("video_channel_home_ar"), channelId: "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(page.name == "Blender")
        #expect(page.isVerified)
        #expect(page.handle == "@BlenderOfficial")
        #expect(page.subscribers?.contains("مشترك") == true)
        #expect(page.videoCount?.contains("فيديو") == true)
        #expect(page.videoCount != page.subscribers)
        #expect(page.avatar?.hasPrefix("https://") == true)
        #expect(page.banner?.hasPrefix("https://") == true)
        #expect(page.description?.isEmpty == false)
        #expect(page.aboutToken?.isEmpty == false)
        let kinds = page.tabs.map(\.kind)
        #expect(kinds.starts(with: [.home, .videos, .shorts, .live]))
        #expect(kinds.contains(.playlists) && kinds.contains(.podcasts))
        #expect(page.tabs.allSatisfy { !$0.title.isEmpty && !$0.params.isEmpty })
        #expect(page.defaultTab?.kind == .videos)
        #expect(page.contentTabs.map(\.kind) == [.videos, .live, .podcasts, .playlists])
        #expect(page.hasShorts)
    }

    @Test func parsesPlaylistsTab() throws {
        let tab = VideoAPI.parseChannelTab(try Fixture.json("video_channel_playlists_ar"), channelId: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender")
        #expect(tab.playlists.count >= 20)
        #expect(tab.videos.isEmpty)
        #expect(tab.continuation?.isEmpty == false)
        #expect(tab.playlists.allSatisfy { $0.id.hasPrefix("PL") && !$0.title.isEmpty && $0.thumbnail?.hasPrefix("https://") == true })
        #expect(tab.playlists.filter { $0.count != nil }.count == tab.playlists.count)
        // The "View full playlist" link is not mistaken for the byline.
        #expect(!tab.playlists.contains { $0.channel.contains("بالكامل") })
    }

    @Test func parsesAbout() throws {
        let about = VideoAPI.parseAbout(try Fixture.json("video_channel_about_ar"))
        #expect(about.description?.isEmpty == false)
        #expect(about.country == "مصر")
        #expect(about.joined?.contains("2017") == true)
        #expect(about.views?.isEmpty == false)
        #expect(about.subscribers?.isEmpty == false)
        #expect(about.videos?.isEmpty == false)
        #expect(about.url == "www.youtube.com/@ta9ueen")
        #expect(about.links.count >= 3)
        #expect(about.links.contains { $0.url.host() == "www.facebook.com" })
        // Links open their target, not YouTube's redirect page.
        #expect(!about.links.contains { $0.url.path() == "/redirect" })
    }

    @Test func unwrapsRedirects() {
        let r = "https://www.youtube.com/redirect?event=channel_description&redir_token=x&q=https%3A%2F%2Ffund.blender.org"
        #expect(VideoAPI.unwrapRedirect(r)?.absoluteString == "https://fund.blender.org")
        #expect(VideoAPI.unwrapRedirect("https://www.youtube.com/redirect?q=Taqueen.com")?.absoluteString == "https://Taqueen.com")
        #expect(VideoAPI.unwrapRedirect("https://example.com/a")?.absoluteString == "https://example.com/a")
    }

    @Test func parsesPlaylistLockups() throws {
        let videos = VideoAPI.parsePlaylistVideos(try Fixture.json("video_playlist_ar"))
        #expect(videos.count >= 20)
        #expect(Set(videos.map(\.id)).count == videos.count)
        #expect(videos.allSatisfy { $0.channel == "Blender" && $0.channelId == "UCSMOQeBJ2RAnuFungnQOxLg" })
        #expect(videos.filter { $0.durationText?.durationSeconds != nil }.count >= videos.count * 8 / 10)
    }
}
