import Foundation
import Testing
@testable import Koda

@Suite struct VideoDownloadTests {
    @Test func labelsQualityByTheLongerSide() {
        #expect(VideoDownloadManager.qualityHeight(width: 1920, height: 1080) == 1080)
        #expect(VideoDownloadManager.qualityHeight(width: 1920, height: 800) == 1080)
        #expect(VideoDownloadManager.qualityHeight(width: 1080, height: 1920) == 1080)
        #expect(VideoDownloadManager.qualityHeight(width: 640, height: 360) == 360)
        #expect(VideoDownloadManager.qualityHeight(width: 426, height: 240) == 240)
        #expect(VideoDownloadManager.qualityHeight(width: 3840, height: 2160) == 2160)
        #expect(VideoDownloadManager.qualityHeight(width: 720, height: 720) == 720)
    }

    @Test func storesLocationsRelativeToTheContainer() {
        let home = "/var/mobile/Containers/Data/Application/ABC-123"
        #expect(VideoDownloadManager.relative(path: "/.nofollow/private/var/mobile/Containers/Data/Application/ABC-123/Library/com.apple.UserManagedAssets.x/a.movpkg", home: home)
                == "Library/com.apple.UserManagedAssets.x/a.movpkg")
        #expect(VideoDownloadManager.relative(path: home + "/Library/Application Support/VideoDownloads/x.m4a", home: home)
                == "Library/Application Support/VideoDownloads/x.m4a")
    }
}

@Suite struct VideoDownloadPlaylistTests {
    @Test func readsVariantSizesFromTheMasterPlaylist() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:URI="https://m.example/itag/234/sgoap/clen%3D10271496%3Bdur%3D634.6/file/index.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="Default",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=4553846,CODECS="avc1.4D4020,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=60,AUDIO="234"
        https://m.example/itag/311/sgovp/clen%3D150524867%3Bdur%3D634.5/file/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=813450,CODECS="avc1.4D401E,mp4a.40.2",RESOLUTION=640x360,AUDIO="999"
        https://m.example/itag/230/sgovp/clen%3D18294110%3Bdur%3D634.5/file/index.m3u8
        """
        let sizes = VideoDownloadManager.parseVariantSizes(master)
        #expect(sizes[4553846] == Int64(150_524_867 + 10_271_496))
        #expect(sizes[813450] == Int64(18_294_110))
    }
}
