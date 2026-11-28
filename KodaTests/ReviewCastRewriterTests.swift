import Foundation
import Testing
@testable import Koda

/// Which proxy resource each tagged URI is rewritten to.
@Suite struct ReviewCastRewriterTests {
    static func tag(_ url: URL, _ resource: HLSPlaylistRewriter.Resource) -> String { "P:\(resource.rawValue):\(url.absoluteString)" }

    @Test func mediaTagsUseTheRightResource() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
        #EXT-X-BYTERANGE:1000@720
        #EXTINF:5.0,
        seg1.mp4
        #EXT-X-RENDITION-REPORT:URI="../other/index.m3u8",LAST-MSN=10
        """
        let base = URL(string: "https://rr1.googlevideo.com/a/b/index.m3u8")!
        let out = HLSPlaylistRewriter.rewrite(text, base: base, proxy: Self.tag)
        #expect(out.contains(#"URI="P:s:https://rr1.googlevideo.com/a/b/key.bin""#))
        #expect(out.contains(#"URI="P:s:https://rr1.googlevideo.com/a/b/init.mp4",BYTERANGE="720@0""#))
        #expect(out.contains("#EXT-X-BYTERANGE:1000@720"))
        #expect(out.contains("\nP:s:https://rr1.googlevideo.com/a/b/seg1.mp4\n"))
        #expect(out.contains(#"URI="P:m:https://rr1.googlevideo.com/a/other/index.m3u8""#))
    }

    @Test func masterSessionKeyIsFetchedAsBytes() {
        let text = """
        #EXTM3U
        #EXT-X-SESSION-KEY:METHOD=AES-128,URI="k.bin"
        #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720
        v.m3u8
        """
        let out = HLSPlaylistRewriter.rewrite(text, base: URL(string: "https://manifest.googlevideo.com/m/x")!, proxy: Self.tag)
        #expect(out.contains(#"URI="P:s:https://manifest.googlevideo.com/m/k.bin""#))
        #expect(out.contains("P:m:https://manifest.googlevideo.com/m/v.m3u8"))
    }
}
