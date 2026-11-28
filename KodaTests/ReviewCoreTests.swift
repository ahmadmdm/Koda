import Foundation
import Testing
@testable import Koda

/// Persistence decoding that used to reject a whole document over one missing key.
@Suite struct ReviewCoreTests {
    @Test func libraryWithMissingListsStillDecodes() throws {
        let json = #"{"likedSongs":[{"song":{"id":"abc","title":"T","artist":"A"},"date":0}],"plays":[]}"#
        let data = try JSONDecoder().decode(LibraryData.self, from: Data(json.utf8))
        #expect(data.likedSongs.count == 1)
        #expect(data.likedSongs[0].song.isVideo == false)
        #expect(data.tasteArtists.isEmpty)
        #expect(data.videoHistory.isEmpty)
    }

    @Test func videoWithoutIsLiveDecodes() throws {
        let json = #"{"id":"v","title":"T","channel":"C","views":"3 views"}"#
        let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
        #expect(video.isLive == false)
        #expect(video.views == "3 views")
    }

    @Test func libraryRoundTrips() throws {
        var data = LibraryData()
        data.videoHistory = [VideoEntry(video: Video(id: "v", title: "T", channel: "C", isLive: true), date: Date(timeIntervalSince1970: 5), position: 12)]
        data.hiddenVideos = ["x"]
        let decoded = try JSONDecoder().decode(LibraryData.self, from: JSONEncoder().encode(data))
        #expect(decoded.videoHistory == data.videoHistory)
        #expect(decoded.hiddenVideos == ["x"])
    }

    @Test func accountWithoutExpiredDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","cookies":"SID=1"}"#
        let account = try JSONDecoder().decode(YouTubeAccount.self, from: Data(json.utf8))
        #expect(account.expired == false)
        #expect(account.cookies == "SID=1")
    }

    @Test func libraryWriterNeverWritesAnOlderSnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = LibraryWriter(url: url)
        var newer = LibraryData(); newer.hiddenVideos = ["new"]
        var older = LibraryData(); older.hiddenVideos = ["old"]
        writer.write(newer, generation: 2)
        writer.write(older, generation: 1)
        let saved = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: url))
        #expect(saved.hiddenVideos == ["new"])
    }
}
