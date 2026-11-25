import Foundation
import Testing
@testable import Koda

@Suite struct MusicAPIParsingTests {
    @Test func parsesSongSearch() throws {
        let (cards, next) = MusicAPI.parseSearch(try Fixture.json("music_search_songs"))
        #expect(cards.count >= 10)
        #expect(next?.isEmpty == false)
        let songs = cards.compactMap(\.song)
        #expect(songs.count == cards.count)
        for song in songs {
            #expect(song.id.count == 11)
            #expect(!song.title.isEmpty)
        }
        // Most songs carry an artist, an album and a duration parsed from the second column.
        #expect(songs.filter { !$0.artist.isEmpty }.count >= songs.count * 9 / 10)
        #expect(songs.filter { ($0.duration ?? 0) > 0 }.count >= songs.count * 9 / 10)
        #expect(songs.filter { $0.albumId?.hasPrefix("MPRE") == true }.count >= songs.count / 2)
        #expect(songs.contains { $0.artist.localizedCaseInsensitiveContains("Fair") })
        #expect(songs.allSatisfy { $0.artistId == nil || $0.artistId!.hasPrefix("UC") })
        #expect(songs.allSatisfy { $0.thumbnail?.hasPrefix("https://") ?? true })
    }

    @Test func parsesHomeShelves() throws {
        let home = MusicAPI.parseHome(try Fixture.json("music_home"))
        // Signed out, the first page holds a couple of shelves and a continuation for the rest.
        #expect(home.shelves.count >= 2)
        #expect(home.continuation?.isEmpty == false)
        for shelf in home.shelves {
            #expect(!shelf.title.isEmpty)
            #expect(!shelf.items.isEmpty)
            for item in shelf.items { #expect(!item.id.isEmpty && !item.title.isEmpty) }
        }
        let kinds = Set(home.shelves.flatMap(\.items).map(\.kind))
        #expect(kinds.count >= 2)
    }

    @Test func parsesAlbum() throws {
        let page = MusicAPI.parseCollection(try Fixture.json("music_album"), id: "MPREb_cxYiFdr77ub")
        #expect(page.isAlbum)
        #expect(page.title == "Shayef El Bahr Shou Kbir")
        #expect(page.subtitle.contains("Fairouz"))
        #expect(page.thumbnail != nil)
        #expect(!page.songs.isEmpty)
        // Album tracks inherit the album, its artwork and the album artist.
        for song in page.songs {
            #expect(song.album == "Shayef El Bahr Shou Kbir")
            #expect(song.albumId == "MPREb_cxYiFdr77ub")
            #expect(song.thumbnail != nil)
            #expect(!song.artist.isEmpty)
            #expect(song.artistId == "UCzixfFiEFMjhSB3R9UdUdsA")
        }
        #expect(Set(page.songs.map(\.id)).count == page.songs.count)
    }

    @Test func parsesPlaylist() throws {
        let page = MusicAPI.parseCollection(try Fixture.json("music_playlist"), id: "VLRDCLAK5uy_k4StAVjLw-w4jWArgFggip1Rfkb152BoM")
        #expect(!page.isAlbum)
        #expect(!page.title.isEmpty && page.title != "Playlist")
        #expect(page.thumbnail != nil)
        #expect(page.songs.count >= 20)
        #expect(Set(page.songs.map(\.id)).count == page.songs.count)
        #expect(page.songs.filter { !$0.artist.isEmpty }.count >= page.songs.count * 9 / 10)
    }

    @Test func parsesArtist() throws {
        let page = MusicAPI.parseArtist(try Fixture.json("music_artist"), browseId: "UCzixfFiEFMjhSB3R9UdUdsA")
        #expect(page.name != "Artist")
        #expect(page.name.localizedCaseInsensitiveContains("Fair"))
        #expect(page.thumbnail != nil)
        #expect(!page.topSongs.isEmpty)
        #expect(!page.shelves.isEmpty)
        #expect(page.shelves.contains { $0.items.contains { $0.kind == .album } })
    }

    @Test func parsesRadio() throws {
        let songs = MusicAPI.parseRadio(try Fixture.json("music_radio"))
        #expect(songs.count >= 20)
        #expect(songs.first?.id == "5NE64kbAe4s")
        for song in songs {
            #expect(!song.title.isEmpty)
            #expect(MusicAPI.isMusicForRadio(song))
        }
        #expect(songs.filter { ($0.duration ?? 0) > 0 }.count == songs.count)
        #expect(songs.filter { !$0.artist.isEmpty }.count == songs.count)
    }

    @Test func radioDropsLongUserUploads() {
        func song(_ seconds: Int?, video: Bool) -> Song {
            Song(id: "x", title: "t", artist: "a", duration: seconds, isVideo: video)
        }
        #expect(MusicAPI.isMusicForRadio(song(4 * 60, video: false)))
        #expect(MusicAPI.isMusicForRadio(song(4 * 60, video: true)))
        #expect(MusicAPI.isMusicForRadio(song(12 * 60, video: false)))
        #expect(!MusicAPI.isMusicForRadio(song(12 * 60, video: true)))
        #expect(!MusicAPI.isMusicForRadio(song(16 * 60, video: false)))
        #expect(!MusicAPI.isMusicForRadio(song(60 * 60, video: true)))
        #expect(MusicAPI.isMusicForRadio(song(nil, video: true)))
    }

    @Test func radioFilterAppliesToParsedPanelItems() {
        func panel(_ id: String, _ length: String, type: String) -> [String: Any] {
            ["playlistPanelVideoRenderer": [
                "videoId": id, "title": ["runs": [["text": "Title " + id]]],
                "lengthText": ["runs": [["text": length]]],
                "shortBylineText": ["runs": [["text": "Someone"]]],
                "navigationEndpoint": ["watchEndpoint": ["watchEndpointMusicSupportedConfigs": [
                    "watchEndpointMusicConfig": ["musicVideoType": type]]]],
            ]]
        }
        let root = J(["contents": [
            panel("song0000001", "3:45", type: "MUSIC_VIDEO_TYPE_ATV"),
            panel("vlog0000001", "1:02:00", type: "MUSIC_VIDEO_TYPE_UGC"),
            panel("ugc00000001", "4:10", type: "MUSIC_VIDEO_TYPE_UGC"),
            panel("ugc00000002", "9:30", type: "MUSIC_VIDEO_TYPE_UGC"),
            panel("omv00000001", "9:30", type: "MUSIC_VIDEO_TYPE_OMV"),
        ]])
        #expect(MusicAPI.parseRadio(root).map(\.id) == ["song0000001", "ugc00000001", "omv00000001"])
    }
}
