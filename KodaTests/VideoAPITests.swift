import Foundation
import Testing
@testable import Koda

@Suite struct VideoAPIParsingTests {
    @Test func parsesSearch() throws {
        let (results, next) = VideoAPI.parseSearch(try Fixture.json("video_search"))
        #expect(results.count >= 10)
        #expect(next?.isEmpty == false)
        #expect(Set(results.map(\.id)).count == results.count)
        let videos = results.compactMap { if case .video(let v) = $0 { v } else { nil } }
        #expect(videos.count >= 10)
        for v in videos {
            #expect(v.id.count == 11)
            #expect(!v.title.isEmpty)
            #expect(!v.channel.isEmpty)
            #expect(v.thumbnail?.hasPrefix("https://") == true)
        }
        #expect(videos.filter { $0.durationText?.durationSeconds != nil }.count >= videos.count * 8 / 10)
        #expect(videos.filter { $0.channelId?.hasPrefix("UC") == true }.count >= videos.count * 8 / 10)
        #expect(videos.filter { $0.views != nil }.count >= videos.count * 8 / 10)
    }

    @Test func parsesWatchPageAndRelated() throws {
        let details = VideoAPI.parseWatch(try Fixture.json("video_next_chapters"), videoId: "UoFK7uY9MnY")
        #expect(!details.title.isEmpty)
        #expect(!details.views.isEmpty)
        #expect(!details.description.isEmpty)
        #expect(details.channel.id == "UCwrVwiJllwhJUKXKmjLcckQ")
        #expect(!details.channel.name.isEmpty)
        #expect(details.related.count >= 5)
        #expect(!details.related.contains { $0.id == "UoFK7uY9MnY" })
        #expect(Set(details.related.map(\.id)).count == details.related.count)
        #expect(details.related.allSatisfy { !$0.title.isEmpty })
    }

    @Test func parsesChaptersFromDescription() throws {
        let details = VideoAPI.parseWatch(try Fixture.json("video_next_chapters"), videoId: "UoFK7uY9MnY")
        let chapters = VideoPlayerModel.parseChapters(details.description)
        #expect(chapters.count >= 5)
        #expect(chapters.first?.time == 0)
        #expect(chapters.allSatisfy { !$0.title.isEmpty })
        #expect(zip(chapters, chapters.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func chapterRules() {
        let text = "Intro text\n0:00 Start\n1:30 - Middle\n(12:05) End part\n1:02:03 Bonus"
        let chapters = VideoPlayerModel.parseChapters(text)
        #expect(chapters.map(\.time) == [0, 90, 725, 3723])
        #expect(chapters.map(\.title) == ["Start", "Middle", "End part", "Bonus"])
        // Fewer than three, or not starting at 0:00, is a timestamp in prose rather than chapters.
        #expect(VideoPlayerModel.parseChapters("0:00 a\n1:00 b").isEmpty)
        #expect(VideoPlayerModel.parseChapters("0:10 a\n1:00 b\n2:00 c").isEmpty)
    }

    @Test func findsCommentsToken() throws {
        let details = VideoAPI.parseWatch(try Fixture.json("video_next_comments"), videoId: "jNQXAC9IVRw")
        #expect(details.commentsToken?.isEmpty == false)
        #expect(details.title.isEmpty == false)
    }

    @Test func parsesComments() throws {
        let (comments, tokens) = VideoAPI.parseComments(try Fixture.json("video_comments"))
        #expect(comments.count >= 10)
        #expect(!tokens.isEmpty)
        #expect(Set(comments.map(\.id)).count == comments.count)
        for c in comments {
            #expect(!c.text.isEmpty)
            #expect(c.author.hasPrefix("@commenter-"))
            #expect(!c.published.isEmpty)
        }
        #expect(comments.filter { $0.likes != nil }.count >= comments.count / 2)
    }

    @Test func parsesChannel() throws {
        let page = VideoAPI.parseChannel(try Fixture.json("video_channel"), channelId: "UCwrVwiJllwhJUKXKmjLcckQ")
        #expect(!page.name.isEmpty)
        #expect(page.handle?.hasPrefix("@") == true)
        #expect(page.avatar != nil)
        #expect(page.videos.count >= 10)
        #expect(page.videos.allSatisfy { !$0.channel.isEmpty && $0.channelId != nil })
    }

    @Test func parsesArabicSuggestions() throws {
        let suggestions = VideoAPI.parseSuggestions(try Fixture.data("video_suggestions_ar"))
        #expect(suggestions.count >= 5)
        #expect(suggestions.first == "فيروز")
        #expect(suggestions.allSatisfy { $0.contains("فيروز") })
        #expect(!suggestions.contains { $0.contains("&#") || $0.contains("\u{FFFD}") })
    }

    @Test func suggestionsDecodeEntities() {
        let data = Data(#"["q",[["&#1601;&#1610;&#1585;&#1608;&#1586; &amp; co",0]]]"#.utf8)
        #expect(VideoAPI.parseSuggestions(data) == ["فيروز & co"])
        #expect(VideoAPI.parseSuggestions(Data("garbage".utf8)).isEmpty)
    }
}

@Suite struct PlayerResponseTests {
    @Test func parsesStreamsAndCaptions() throws {
        let info = InnerTube.parseStream(try Fixture.json("player_captions"))
        #expect(info.audioURL != nil)
        #expect(info.lowAudioURL != nil)
        #expect(info.hlsURL != nil)
        #expect(!info.title.isEmpty)
        #expect(!info.author.isEmpty)
        #expect(info.duration > 60)
        #expect(!info.isLive)
        #expect(info.captions.count >= 1)
        for track in info.captions {
            #expect(!track.language.isEmpty)
            #expect(!track.name.isEmpty)
            #expect(track.url.absoluteString.hasSuffix("&fmt=vtt"))
        }
        // Uploaded English captions and YouTube's auto-generated ("asr") ones are told apart.
        #expect(info.captions.contains { $0.language == "en" && !$0.isAutoGenerated })
        #expect(info.captions.contains { $0.language == "en" && $0.isAutoGenerated })
        #expect(info.originalAudioLanguage == nil)
    }

    @Test func findsOriginalAudioLanguageAmongDubs() throws {
        let root = try Fixture.json("player_audio_tracks")
        let info = InnerTube.parseStream(root)
        // `audioTrack.id` is "en-US.4" on the default track: the tag before the dot, compared with the HLS option's tag.
        #expect(info.originalAudioLanguage == "en-US")
        #expect(info.captions.count >= 2)
        #expect(info.captions.contains { $0.language == "ar" && !$0.isAutoGenerated })
        // Several dubbed audio tracks are listed beside the original.
        let trackIds = Set(root.path("streamingData.adaptiveFormats").array.compactMap { $0.path("audioTrack.id").string })
        #expect(trackIds.count >= 3)
        #expect(info.audioURL != nil)
    }

    @Test func liveNeedsBothFlags() {
        let base: [String: Any] = ["streamingData": ["hlsManifestUrl": "https://example.com/x.m3u8"]]
        var live = base; live["videoDetails"] = ["isLiveContent": true, "isLive": true, "lengthSeconds": "0"]
        var past = base; past["videoDetails"] = ["isLiveContent": true, "lengthSeconds": "3600"]
        #expect(InnerTube.parseStream(J(live)).isLive)
        #expect(!InnerTube.parseStream(J(past)).isLive)
        #expect(InnerTube.parseStream(J(past)).duration == 3600)
    }
}
