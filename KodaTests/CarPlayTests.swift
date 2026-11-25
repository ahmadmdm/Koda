import Foundation
import Testing
@testable import Koda

@Suite struct CarPlayCatalogTests {
    @Test func parsesMoodsAndGenres() throws {
        let groups = MusicAPI.parseMoods(try Fixture.json("music_moods"))
        #expect(groups.map(\.title) == ["Moods & moments", "Genres"])
        let moods = groups[0].categories
        #expect(moods.count >= 8)
        #expect(moods.contains { $0.title == "Commute" })
        for category in groups.flatMap(\.categories) {
            #expect(!category.title.isEmpty)
            #expect(!category.params.isEmpty)
            #expect(category.color != nil)
        }
        #expect(groups[1].categories.contains { $0.title == "Arabic" })
    }
}

@Suite struct MixPlannerTests {
    private func song(_ id: String, artist: String = "Artist") -> Song {
        Song(id: id, title: "Song \(id)", artist: artist)
    }

    private func play(_ s: Song, hour: Int) -> PlayRecord {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
        return PlayRecord(song: s, date: date, seconds: 120)
    }

    @Test func daypartsCoverTheDay() {
        #expect(Daypart(hour: 7) == .morning)
        #expect(Daypart(hour: 13) == .afternoon)
        #expect(Daypart(hour: 19) == .evening)
        #expect(Daypart(hour: 23) == .night)
        #expect(Daypart(hour: 3) == .night)
    }

    @Test func emptyLibraryHasNoMixesButTasteArtists() {
        #expect(MixPlanner.mixes(for: MixInputs(), hour: 9, limit: 8).isEmpty)
        let mixes = MixPlanner.mixes(for: MixInputs(tasteArtists: ["Fairuz", "fairuz", "Umm Kulthum"]), hour: 9, limit: 8)
        #expect(mixes.map(\.kind) == [.artist("Fairuz"), .artist("Umm Kulthum")])
    }

    @Test func mixesFollowTheLibraryAndTheLimit() {
        let a = song("a"), b = song("b")
        let inputs = MixInputs(liked: [a], top: [b], plays: [play(b, hour: 8)], offline: [a],
                               tasteArtists: ["X", "Y", "Z", "W"], topArtists: ["Artist"])
        let mixes = MixPlanner.mixes(for: inputs, hour: 8, limit: 20)
        #expect(mixes.first?.kind == .drive)
        #expect(mixes.contains { $0.kind == .daypart(.morning) })
        #expect(mixes.contains { $0.kind == .fresh })
        #expect(mixes.filter { if case .artist = $0.kind { true } else { false } }.count == MixPlanner.maximumArtistMixes)
        #expect(mixes.last?.kind == .offline)
        #expect(MixPlanner.mixes(for: inputs, hour: 8, limit: 2).count == 2)
    }

    @Test func freshFindsLeaveOutKnownSongs() {
        let known = song("known"), liked = song("liked")
        let inputs = MixInputs(liked: [liked], plays: [play(known, hour: 10)])
        let plan = MixPlanner.plan(DriveMix(kind: .fresh), inputs: inputs, hour: 10)
        #expect(plan.radioSeeds == ["known"])
        let queue = MixPlanner.assemble(plan, radios: [[known, song("new1"), liked, song("new2")]])
        #expect(Set(queue.map(\.id)) == ["new1", "new2"])
    }

    @Test func daypartMixStartsWithThisHoursFavourite() {
        let morning = song("m"), night = song("n")
        let plays = [play(morning, hour: 8), play(morning, hour: 9), play(night, hour: 23)]
        let plan = MixPlanner.plan(DriveMix(kind: .daypart(.morning)), inputs: MixInputs(plays: plays), hour: 8)
        #expect(plan.base.map(\.id) == ["m"])
        let queue = MixPlanner.assemble(plan, radios: [[song("r1"), morning, song("r2")]])
        #expect(queue.first?.id == "m")
        #expect(queue.count == 3)
    }

    @Test func artistMixUsesTheLibraryFirst() {
        let mine = song("mine", artist: "Fairuz"), other = song("other", artist: "Someone")
        let inputs = MixInputs(liked: [mine, other])
        let plan = MixPlanner.plan(DriveMix(kind: .artist("fairuz")), inputs: inputs, hour: 12)
        #expect(plan.base.map(\.id) == ["mine"])
        #expect(plan.searchArtist == "fairuz")
        let queue = MixPlanner.assemble(plan, radios: [[song("r1"), song("r2")]])
        #expect(queue.map(\.id) == ["mine", "r1", "r2"])
    }

    @Test func assembleCapsAndDeduplicates() {
        let base = (0..<5).map { song("b\($0)") }
        let radio = (0..<200).map { song("r\($0)") } + base
        let queue = MixPlanner.assemble(MixPlan(base: base, radioSeeds: [], shuffleAll: true), radios: [radio], limit: 50)
        #expect(queue.count == 50)
        #expect(Set(queue.map(\.id)).count == 50)
        #expect(queue.first?.id == "b0")
    }
}
