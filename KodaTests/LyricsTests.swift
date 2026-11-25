import Foundation
import Testing
@testable import Koda

@Suite struct LyricsParsingTests {
    @Test func parsesTimedLines() {
        let lrc = """
        [ar:Someone]
        [00:12.50] First line
        [00:05.00]Earlier line
        [01:02.123] يا قمر

        not a lyric line
        """
        let lines = LyricsService.parseLRC(lrc)
        #expect(lines.map(\.text) == ["Earlier line", "First line", "يا قمر"])
        #expect(lines.map(\.time) == [5, 12.5, 62.123])
        #expect(lines.map(\.id) == [0, 1, 2])
    }

    @Test func repeatsLinesWithSeveralTimestamps() {
        let lines = LyricsService.parseLRC("[00:10.00][00:30.00]Chorus\n[00:20.00]Verse")
        #expect(lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
        #expect(lines.map(\.time) == [10, 20, 30])
    }

    @Test func keepsInstrumentalGapsAndWholeSeconds() {
        let lines = LyricsService.parseLRC("[00:01]Start\n[00:04.00]\n[02:00] End")
        #expect(lines.map(\.text) == ["Start", "", "End"])
        #expect(lines.map(\.time) == [1, 4, 120])
    }

    @Test func emptyInput() {
        #expect(LyricsService.parseLRC("").isEmpty)
        #expect(LyricsService.parseLRC("plain lyrics\nwithout timing").isEmpty)
    }
}
