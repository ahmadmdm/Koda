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

@Suite struct HLSPackageRemuxerTests {
    @Test func readsTheSegmentsOfAStreamInOrder() {
        let xml = """
        <MediaSegments>
        <SEG Dur="4.33" Len="111672" Off="0" PATH="(4.03333)_(0)_(4.33334).frag" SeqNum="1" Tim="4.03" URL="https://x/a&amp;b" />
        <SEG Dur="4.03" Len="36472" Off="0" PATH="(0)_(0)_(4.03334).frag" SeqNum="0" Tim="0.000000" URL="https://x" />
        </MediaSegments>
        """
        let segments = HLSPackageRemuxer.parseSegments(xml)
        #expect(segments.map(\.path) == ["(0)_(0)_(4.03334).frag", "(4.03333)_(0)_(4.33334).frag"])
        #expect(segments.first?.length == 36472)
    }

    @Test func readsThePackedAudioTimestamp() {
        let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]
        let stamp: [UInt8] = [0, 0, 0, 1, 0, 0, 0x2E, 0xE0] // 2^32 + 12000
        let frame = Array("PRIV".utf8) + [0, 0, 0, UInt8(owner.count + 8), 0, 0] + owner + stamp
        let tag: [UInt8] = Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, UInt8(frame.count)] + frame
        #expect(HLSPackageRemuxer.id3Timestamp(tag) == Int64(4_294_979_296))

        // One ADTS frame (AAC LC, 44.1 kHz, stereo) of 3 payload bytes after the tag.
        let adts: [UInt8] = [0xFF, 0xF1, 0x50, 0x80, 0x01, 0x5F, 0xFC, 0xAA, 0xBB, 0xCC]
        var start: Int64?
        let frames = HLSPackageRemuxer.parsePackedAudio(Data(tag + adts), startPTS: &start)
        #expect(frames.count == 1)
        #expect(frames.first?.pts == Int64(4_294_979_296))
        #expect(frames.first?.sampleRate == 44100)
        #expect(frames.first?.channels == 2)
        #expect(frames.first?.payload == Data([0xAA, 0xBB, 0xCC]))
        #expect(frames.first?.audioSpecificConfig == [0x12, 0x10])
        #expect(start == frames[0].pts + frames[0].duration)
        // The cookie is a whole ES_Descriptor, which is what the mp4 esds box holds.
        let cookie = frames[0].esdsCookie
        #expect(cookie.first == 0x03 && Int(cookie[1]) == cookie.count - 2)
        #expect(cookie.suffix(5) == [0x12, 0x10, 0x06, 0x01, 0x02])
    }

    @Test func splitsAnnexBIntoNALUnits() {
        let stream: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x65, 9, 9]
        #expect(TSDemuxer.nalUnits(stream).map(Array.init) == [[0x09, 0xF0], [0x67, 1, 2], [0x65, 9, 9]])
    }

    @Test func readsPESTimestamps() {
        // PTS 0x1_0000_0001 encoded in the 5-byte PES form.
        let bytes: [UInt8] = [0x21 | 0x08, 0x00, 0x01, 0x00, 0x03]
        #expect(TSDemuxer.timestamp(bytes[...]) == Int64(4_294_967_297))
    }
}
