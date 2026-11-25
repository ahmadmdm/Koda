import Foundation
import Testing
@testable import Koda

@Suite struct JSONHelperTests {
    @Test func decodesNamedEntities() {
        #expect("Tom &amp; Jerry".decodingHTMLEntities == "Tom & Jerry")
        #expect("&lt;b&gt; &quot;hi&quot; &apos;x&apos; &#39;y&#39;".decodingHTMLEntities == "<b> \"hi\" 'x' 'y'")
        #expect("a&nbsp;b".decodingHTMLEntities == "a b")
    }

    @Test func decodesNumericArabicEntities() {
        // فيروز as decimal and as hex references.
        #expect("&#1601;&#1610;&#1585;&#1608;&#1586;".decodingHTMLEntities == "فيروز")
        #expect("&#x641;&#x64A;&#x631;&#x648;&#x632;".decodingHTMLEntities == "فيروز")
        #expect("أغاني &#1601;&#1610;&#1585;&#1608;&#1586; &amp; وديع".decodingHTMLEntities == "أغاني فيروز & وديع")
    }

    @Test func leavesUnknownOrBrokenEntitiesAlone() {
        #expect("plain text".decodingHTMLEntities == "plain text")
        #expect("AT&T".decodingHTMLEntities == "AT&T")
        #expect("&bogus; & more".decodingHTMLEntities == "&bogus; & more")
        #expect("&#xZZ;".decodingHTMLEntities == "&#xZZ;")
        #expect("fish &chips and a very long tail; here".decodingHTMLEntities == "fish &chips and a very long tail; here")
        #expect("trailing &".decodingHTMLEntities == "trailing &")
        #expect("فيروز".decodingHTMLEntities == "فيروز")
    }

    @Test(arguments: [
        ("4:27", 267), ("0:05", 5), ("1:02:03", 3723), ("10:00", 600), ("59", 59),
    ])
    func parsesDurations(text: String, seconds: Int) {
        #expect(text.durationSeconds == seconds)
    }

    @Test(arguments: ["", "abc", "4:2x", "1:2:3:4", "Song", "3 views"])
    func rejectsNonDurations(text: String) {
        #expect(text.durationSeconds == nil)
    }

    @Test func formatsDurations() {
        #expect(267.formattedDuration == "4:27")
        #expect(3723.formattedDuration == "1:02:03")
        #expect(Double.nan.formattedDuration == "0:00")
        #expect((-3.0).formattedDuration == "0:00")
        #expect(61.9.formattedDuration == "1:01")
    }

    @Test func readsTextInAllThreeSpellings() {
        #expect(J(["simpleText": "a"]).text == "a")
        #expect(J(["content": "b"]).text == "b")
        #expect(J(["runs": [["text": "c"], ["text": "d"]]]).text == "cd")
        #expect(J("e").text == "e")
        #expect(J(["other": 1]).text == nil)
    }

    @Test func followsPathsAndFindsKeys() {
        let j = J(["a": ["b": [["c": 1], ["c": 2, "d": ["c": 3]]]]])
        #expect(j.path("a.b.1.c").int == 2)
        #expect(j.path("a.b.5.c").exists == false)
        #expect(j.findAll("c").compactMap(\.int).sorted() == [1, 2, 3])
        #expect(J(NSNull()).exists == false)
    }

    @Test func picksLargestThumbnail() {
        let j = J(["thumbnail": ["thumbnails": [
            ["url": "//small", "width": 60], ["url": "//big", "width": 544], ["url": "//mid", "width": 226],
        ]]])
        #expect(j.bestThumbnail == "https://big")
    }

    @Test func upscalesThumbnails() {
        #expect("https://lh3.googleusercontent.com/x=w120-h120-l90-rj".upscaledThumbnail() == "https://lh3.googleusercontent.com/x=w544-h544-l90-rj")
        #expect("https://yt3.ggpht.com/y=s88-c-k".upscaledThumbnail(300) == "https://yt3.ggpht.com/y=s300-c-k")
        #expect("https://i.ytimg.com/vi/abc/hqdefault.jpg".upscaledThumbnail() == "https://i.ytimg.com/vi/abc/hqdefault.jpg")
    }
}
