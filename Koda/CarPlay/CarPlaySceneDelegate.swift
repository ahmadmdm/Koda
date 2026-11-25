import CarPlay
import MediaPlayer
import Observation
import UIKit

/// Koda in the car: an audio app with Home, Library, History and Explore tabs, and the system
/// Now Playing screen with shuffle, like, radio, speed and a sleep-timer/repeat sheet.
///
/// Home: Continue listening, For the Drive mixes, Your artists, Speed dial, Quick picks, Liked songs.
/// Library: liked songs, downloads, songs on this iPhone, playlists, saved albums and artists.
/// Explore: YouTube Music's Moods & genres, then its Home shelves.
/// Every list respects `CPListTemplate.maximumItemCount` and `maximumSectionCount`, and rebuilds
/// only when what it shows changes.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var interfaceController: CPInterfaceController?
    private var tabBar: CPTabBarTemplate?
    private let home = CPListTemplate(title: String(localized: "Home"), sections: [])
    private let libraryList = CPListTemplate(title: String(localized: "Library"), sections: [])
    private let history = CPListTemplate(title: String(localized: "History"), sections: [])
    private let explore = CPListTemplate(title: String(localized: "Explore"), sections: [])

    private var player: MusicPlayer { .shared }
    private var library: LibraryStore { .shared }

    private enum Remote: Equatable { case loading, loaded, failed }

    // Home: what comes from the network, kept so local changes rebuild Home without refetching.
    private var homeRemote = Remote.loading
    private var quickPicks: [Song] = []
    private var homeFallback: [MusicShelf] = []
    private var buildingMix = false

    // Explore
    private var exploreRemote = Remote.loading
    private var moods: [MoodGroup] = []
    private var exploreShelves: [MusicShelf] = []

    // Signatures of what each screen last showed.
    private var lastHomeState = ""
    private var lastLibraryState = ""
    private var lastButtonState = ""

    // MARK: Connection

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        home.tabImage = UIImage(systemName: "house.fill")
        home.emptyViewTitleVariants = [String(localized: "Nothing here yet")]
        libraryList.tabImage = UIImage(systemName: "music.note.square.stack.fill")
        history.tabImage = UIImage(systemName: "clock.fill")
        history.emptyViewTitleVariants = [String(localized: "No history")]
        history.emptyViewSubtitleVariants = [String(localized: "Songs you play show up here.")]
        explore.tabImage = UIImage(systemName: "sparkles")
        let templates = [home, libraryList, history, explore].prefix(max(1, CPTabBarTemplate.maximumTabCount))
        let tabs = CPTabBarTemplate(templates: Array(templates))
        tabBar = tabs
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        configureNowPlaying()
        loadHomeRemote()
        loadExplore()
        observe()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CPNowPlayingTemplate.shared.remove(self)
        self.interfaceController = nil
        tabBar = nil
        lastHomeState = ""; lastLibraryState = ""; lastButtonState = ""
    }

    // MARK: Observation

    /// Rebuilds whatever changed in the library or the player, then watches again. Each screen
    /// compares a small signature first, so the frequent play-time updates cost almost nothing.
    private func observe() {
        guard tabBar != nil else { return }
        withObservationTracking {
            refreshHome()
            refreshLibraryTabs()
            refreshNowPlayingButtons()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    // MARK: Home

    private func loadHomeRemote() {
        homeRemote = .loading
        refreshHome(force: true)
        Task {
            let seed = library.recentSongs.first(where: { !$0.isLocal }) ?? library.data.likedSongs.first?.song
            var failed = false
            if let seed {
                if let picks = try? await MusicAPI.radio(for: seed.id) {
                    quickPicks = Array(picks.filter { $0.id != seed.id }.prefix(12))
                } else {
                    failed = true
                }
            }
            // A new listener has no seed: show YouTube Music's own Home instead.
            if seed == nil || quickPicks.isEmpty {
                if let shelves = try? await MusicAPI.home().shelves { homeFallback = Array(shelves.prefix(3)); failed = false }
                else { failed = true }
            }
            homeRemote = failed && quickPicks.isEmpty && homeFallback.isEmpty ? .failed : .loaded
            refreshHome(force: true)
        }
    }

    private func refreshHome(force: Bool = false) {
        let data = library.data
        let current = player.current
        let paused = current != nil && !player.isPlaying
        let state = [
            "\(data.plays.count)|\(data.likedSongs.count)|\(data.downloads.count)|\(LocalMusicLibrary.shared.songs.count)",
            data.tasteArtists.joined(separator: ","),
            "\(current?.id ?? "")|\(paused)|\(homeRemote)|\(quickPicks.count)|\(homeFallback.count)",
            Daypart(hour: Calendar.current.component(.hour, from: .now)).rawValue,
        ].joined(separator: "|")
        guard force || state != lastHomeState else { return }
        lastHomeState = state
        apply(homeSections(), to: home)
    }

    private func homeSections() -> [Section] {
        var sections: [Section] = []
        if let song = player.current, !player.isPlaying {
            sections.append(Section(header: String(localized: "Continue listening"), items: [continueItem(song)]))
        }
        let inputs = MixBuilder.inputs()
        let mixes = MixPlanner.mixes(for: inputs, hour: Calendar.current.component(.hour, from: .now), limit: 12)
        if !mixes.isEmpty { sections.append(Section(items: [mixRow(mixes)])) }
        let artists = topArtists(limit: Int(CPMaximumNumberOfGridImages))
        if artists.count >= 3 { sections.append(Section(items: [artistRow(artists)])) }
        let top = inputs.top.prefix(Int(CPMaximumNumberOfGridImages)).map { $0 }
        if top.count >= 4 { sections.append(Section(items: [speedDialRow(top)])) }

        switch homeRemote {
        case .loading:
            sections.append(Section(header: String(localized: "Quick picks"), items: [loadingItem()]))
        case .failed:
            sections.append(Section(items: offlineItems { [weak self] in self?.loadHomeRemote() }))
        case .loaded:
            if !quickPicks.isEmpty {
                sections.append(Section(header: String(localized: "Quick picks"), items: songItems(quickPicks)))
            }
        }
        let liked = library.data.likedSongs.prefix(12).map(\.song)
        if !liked.isEmpty { sections.append(Section(header: String(localized: "Liked songs"), items: songItems(liked))) }
        for shelf in homeFallback { sections.append(Section(header: shelf.title, items: cardItems(Array(shelf.items.prefix(10))))) }
        return sections
    }

    /// The last song, paused: one tap resumes it where it stopped.
    private func continueItem(_ song: Song) -> CPListItem {
        let duration = player.duration > 0 ? player.duration : Double(song.duration ?? 0)
        let position = player.currentTime
        var detail = song.artist
        if duration > 0, position > 1 {
            let left = Int(max(0, duration - position)).formattedDuration
            detail = String(localized: "\(song.artist) · \(left) left")
        }
        let item = CPListItem(text: song.title, detailText: detail, image: CarPlayArtwork.cached(song.artwork) ?? CarPlayArtwork.placeholder,
                              accessoryImage: UIImage(systemName: "play.circle.fill"), accessoryType: .none)
        if duration > 0 { item.playbackProgress = min(1, max(0, position / duration)) }
        item.handler = { [weak self] _, completion in
            self?.player.play()
            self?.showNowPlaying()
            completion()
        }
        loadImage(song.artwork, into: item)
        return item
    }

    // MARK: For the Drive

    private func mixRow(_ mixes: [DriveMix]) -> CPListImageRowItem {
        let shown = Array(mixes.prefix(Int(CPMaximumNumberOfGridImages)))
        let elements = shown.map { mix in
            CPListImageRowItemCardElement(image: mixTile(mix), showsImageFullHeight: false, title: mix.title,
                                          subtitle: mix.subtitle, tintColor: mixColor(mix))
        }
        let row = CPListImageRowItem(text: String(localized: "For the Drive"), cardElements: elements, allowsMultipleLines: false)
        row.listImageRowHandler = { [weak self] _, index, completion in
            guard let self, shown.indices.contains(index) else { completion(); return }
            self.start(shown[index], completion: completion)
        }
        // The row's title opens every mix as a list.
        row.handler = { [weak self] _, completion in
            self?.pushMixes(mixes); completion()
        }
        return row
    }

    private func pushMixes(_ mixes: [DriveMix]) {
        let items = mixes.map { mix -> CPListItem in
            let item = CPListItem(text: mix.title, detailText: mix.subtitle, image: mixTile(mix))
            item.handler = { [weak self] _, completion in self?.start(mix, completion: completion) }
            return item
        }
        let t = CPListTemplate(title: String(localized: "For the Drive"), sections: [])
        apply([Section(items: items)], to: t)
        interfaceController?.pushTemplate(t, animated: true, completion: nil)
    }

    /// Builds the mix (the list shows its spinner meanwhile), then plays it.
    private func start(_ mix: DriveMix, completion: @escaping () -> Void) {
        guard !buildingMix else { completion(); return }
        buildingMix = true
        Task {
            let songs = await MixBuilder.build(mix)
            buildingMix = false
            completion()
            guard !songs.isEmpty else {
                alert(String(localized: "Couldn't make this mix"),
                      message: String(localized: "Check your connection, or play your downloads."))
                return
            }
            player.play(songs, startAt: 0)
            showNowPlaying()
        }
    }

    private func mixTile(_ mix: DriveMix) -> UIImage {
        CarPlayArtwork.tile(symbol: mix.symbol, colors: CarPlayArtwork.shades(mixColor(mix)))
    }

    private func mixColor(_ mix: DriveMix) -> UIColor {
        UIColor(hue: mix.hue, saturation: 0.7, brightness: 0.85, alpha: 1)
    }

    // MARK: Your artists

    private struct ArtistSummary { var id: String; var name: String; var artwork: URL? }

    /// The most played artists of the recent history that have a YouTube Music page.
    private func topArtists(limit: Int) -> [ArtistSummary] {
        var counts: [String: (name: String, plays: Int, artwork: URL?)] = [:]
        for p in library.data.plays.suffix(3000) {
            guard let id = p.song.artistId, !p.song.isLocal else { continue }
            let name = p.song.artist.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? p.song.artist
            guard !name.isEmpty else { continue }
            let c = counts[id] ?? (name, 0, p.song.artwork)
            counts[id] = (c.name, c.plays + 1, c.artwork)
        }
        return counts.sorted { $0.value.plays > $1.value.plays }.prefix(limit)
            .map { ArtistSummary(id: $0.key, name: $0.value.name, artwork: $0.value.artwork) }
    }

    private func artistRow(_ artists: [ArtistSummary]) -> CPListImageRowItem {
        let elements = artists.map {
            CPListImageRowItemImageGridElement(image: CarPlayArtwork.cached($0.artwork) ?? CarPlayArtwork.placeholder,
                                               imageShape: .circular, title: $0.name, accessorySymbolName: nil)
        }
        let row = CPListImageRowItem(text: String(localized: "Your artists"), imageGridElements: elements, allowsMultipleLines: false)
        row.listImageRowHandler = { [weak self] _, index, completion in
            if artists.indices.contains(index) { self?.openArtist(id: artists[index].id, name: artists[index].name) }
            completion()
        }
        row.handler = { [weak self] _, completion in
            if let first = artists.first { self?.openArtist(id: first.id, name: first.name) }
            completion()
        }
        loadImages(artists.map(\.artwork), into: row)
        return row
    }

    // MARK: Speed dial

    private func speedDialRow(_ songs: [Song]) -> CPListImageRowItem {
        let elements = songs.map {
            CPListImageRowItemImageGridElement(image: CarPlayArtwork.cached($0.artwork) ?? CarPlayArtwork.placeholder,
                                               imageShape: .roundedRectangle, title: $0.title, accessorySymbolName: nil)
        }
        let row = CPListImageRowItem(text: String(localized: "Speed dial"), imageGridElements: elements, allowsMultipleLines: false)
        row.listImageRowHandler = { [weak self] _, index, completion in
            self?.play(songs, at: index); completion()
        }
        row.handler = { [weak self] _, completion in self?.play(songs, at: 0); completion() }
        loadImages(songs.map(\.artwork), into: row)
        return row
    }

    // MARK: Library and History

    private func refreshLibraryTabs() {
        // The library changes every few seconds while a play is recorded: rebuild only for what the tabs show.
        let data = library.data
        let state = [
            "\(data.plays.count)|\(data.plays.last?.song.id ?? "")",
            "\(data.likedSongs.count)|\(data.downloads.count)|\(LocalMusicLibrary.shared.songs.count)",
            data.playlists.map { "\($0.name)\($0.songs.count)" }.joined(separator: ","),
            (data.savedCollections + data.followedArtists).map(\.id).joined(separator: ","),
            player.current?.id ?? "",
        ].joined(separator: "|")
        guard state != lastLibraryState else { return }
        lastLibraryState = state
        apply(librarySections(), to: libraryList)
        let recent = Array(library.recentSongs.prefix(60))
        var sections: [Section] = []
        if recent.count > 1 {
            let shuffle = CPListItem(text: String(localized: "Shuffle history"), detailText: nil, image: CarPlayArtwork.symbol("shuffle"))
            shuffle.handler = { [weak self] _, completion in self?.shuffle(recent); completion() }
            sections.append(Section(items: [shuffle]))
        }
        if !recent.isEmpty { sections.append(Section(header: String(localized: "Recently played"), items: songItems(recent))) }
        apply(sections, to: history)
    }

    private func librarySections() -> [Section] {
        var rows: [CPListItem] = []
        func folder(_ title: String, _ icon: String, count: Int, songs: @escaping () -> [Song]) {
            let item = CPListItem(text: title, detailText: "\(count)", image: CarPlayArtwork.symbol(icon))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushSongs(title) { SongPage(songs: songs()) }
                completion()
            }
            rows.append(item)
        }
        folder(String(localized: "Liked songs"), "heart.fill", count: library.data.likedSongs.count) { [weak self] in
            self?.library.data.likedSongs.map(\.song) ?? []
        }
        folder(String(localized: "Downloads"), "arrow.down.circle.fill", count: library.data.downloads.count) { [weak self] in
            self?.library.data.downloads.map(\.song) ?? []
        }
        let local = LocalMusicLibrary.shared.songs
        if !local.isEmpty {
            folder(String(localized: "On this iPhone"), "iphone", count: local.count) { LocalMusicLibrary.shared.songs }
        }
        var sections = [Section(items: rows)]
        let playlists = library.data.playlists.map { p -> CPListItem in
            let item = CPListItem(text: p.name, detailText: String(localized: "\(p.songs.count) songs"), image: CarPlayArtwork.symbol("music.note.list"))
            item.accessoryType = .disclosureIndicator
            if let cover = p.songs.first?.artwork { loadImage(cover, into: item) }
            item.handler = { [weak self] _, completion in
                let id = p.id
                self?.pushSongs(p.name) { SongPage(songs: LibraryStore.shared.playlist(id)?.songs ?? []) }
                completion()
            }
            return item
        }
        if !playlists.isEmpty { sections.append(Section(header: String(localized: "Playlists"), items: playlists)) }
        if !library.data.savedCollections.isEmpty {
            sections.append(Section(header: String(localized: "Albums & playlists"), items: cardItems(library.data.savedCollections)))
        }
        if !library.data.followedArtists.isEmpty {
            sections.append(Section(header: String(localized: "Artists"), items: cardItems(library.data.followedArtists)))
        }
        return sections
    }

    // MARK: Explore

    private func loadExplore() {
        exploreRemote = .loading
        apply([Section(items: [loadingItem()])], to: explore)
        Task {
            async let moodsResult = try? MusicAPI.moodsAndGenres()
            async let homeResult = try? MusicAPI.home()
            let (groups, page) = await (moodsResult, homeResult)
            moods = groups ?? []
            exploreShelves = page?.shelves ?? []
            exploreRemote = moods.isEmpty && exploreShelves.isEmpty ? .failed : .loaded
            apply(exploreSections(), to: explore)
        }
    }

    private func exploreSections() -> [Section] {
        guard exploreRemote != .failed else {
            return [Section(items: offlineItems { [weak self] in self?.loadExplore() })]
        }
        var sections: [Section] = []
        for (i, group) in moods.enumerated() {
            // Commute leads the moods: it is what a driver most likely wants.
            var categories = group.categories
            if i == 0, let commute = categories.firstIndex(where: { $0.title.localizedCaseInsensitiveContains("Commute") }) {
                categories.insert(categories.remove(at: commute), at: 0)
            }
            sections.append(Section(items: [moodRow(group.title, categories)]))
        }
        for shelf in exploreShelves.prefix(8) {
            sections.append(Section(header: shelf.title, items: cardItems(Array(shelf.items.prefix(10)))))
        }
        return sections
    }

    private func moodRow(_ title: String, _ categories: [MoodCategory]) -> CPListImageRowItem {
        let shown = Array(categories.prefix(Int(CPMaximumNumberOfGridImages)))
        let elements = shown.map {
            CPListImageRowItemImageGridElement(image: moodTile($0), imageShape: .roundedRectangle, title: $0.title, accessorySymbolName: nil)
        }
        let row = CPListImageRowItem(text: title, imageGridElements: elements, allowsMultipleLines: false)
        row.listImageRowHandler = { [weak self] _, index, completion in
            if shown.indices.contains(index) { self?.openMood(shown[index]) }
            completion()
        }
        // The row's title lists every category of the group.
        row.handler = { [weak self] _, completion in
            guard let self else { completion(); return }
            let items = categories.map { category -> CPListItem in
                let item = CPListItem(text: category.title, detailText: nil, image: self.moodTile(category))
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in self?.openMood(category); completion() }
                return item
            }
            let t = CPListTemplate(title: title, sections: [])
            self.apply([Section(items: items)], to: t)
            self.interfaceController?.pushTemplate(t, animated: true, completion: nil)
            completion()
        }
        return row
    }

    private func moodTile(_ category: MoodCategory) -> UIImage {
        let base = category.color.map(CarPlayArtwork.color(argb:)) ?? .systemIndigo
        return CarPlayArtwork.tile(symbol: Self.moodSymbol(category.title), colors: CarPlayArtwork.shades(base))
    }

    private static func moodSymbol(_ title: String) -> String {
        let t = title.lowercased()
        let table: [(String, String)] = [
            ("commute", "car.fill"), ("chill", "leaf.fill"), ("energ", "bolt.fill"), ("feel good", "face.smiling"),
            ("focus", "scope"), ("gaming", "gamecontroller.fill"), ("party", "party.popper.fill"), ("romance", "heart.fill"),
            ("sad", "cloud.rain.fill"), ("sleep", "moon.zzz.fill"), ("workout", "figure.run"), ("classical", "pianokeys"),
            ("jazz", "music.quarternote.3"), ("rock", "guitars.fill"), ("metal", "flame.fill"), ("hip-hop", "music.mic"),
            ("dance", "sparkles"), ("decades", "clock.arrow.circlepath"), ("seasonal", "snowflake"), ("arab", "moon.stars.fill"),
            ("khaleeji", "sun.horizon.fill"), ("iraqi", "music.note.house.fill"), ("latin", "sun.max.fill"),
        ]
        return table.first { t.contains($0.0) }?.1 ?? "music.note"
    }

    private func openMood(_ category: MoodCategory) {
        let t = CPListTemplate(title: category.title, sections: [])
        push(t) { [weak self] in
            guard let self, let shelves = try? await MusicAPI.moodPlaylists(category) else { return nil }
            return shelves.map { Section(header: $0.title, items: self.cardItems(Array($0.items.prefix(12)))) }
        }
    }

    // MARK: Pages

    private struct Section {
        var header: String?
        var items: [any CPListTemplateItem]
    }

    /// What a page of songs shows: the songs, and for the header its artwork and a radio seed.
    private struct SongPage {
        var songs: [Song]
        var subtitle: String?
        var artwork: URL?
    }

    /// Puts sections on a template, trimmed to the car's section and item limits.
    private func apply(_ sections: [Section], to template: CPListTemplate) {
        var budget = Int(CPListTemplate.maximumItemCount)
        var out: [CPListSection] = []
        for section in sections.filter({ !$0.items.isEmpty }).prefix(Int(CPListTemplate.maximumSectionCount)) {
            guard budget > 0 else { break }
            let items = Array(section.items.prefix(budget))
            budget -= items.count
            out.append(CPListSection(items: items, header: section.header, sectionIndexTitle: nil))
        }
        template.updateSections(out)
    }

    /// Pushes a template showing "Loading…", then fills it; a failed load offers to try again.
    private func push(_ template: CPListTemplate, load: @escaping () async -> [Section]?) {
        template.emptyViewTitleVariants = [String(localized: "Nothing here yet")]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        fill(template, load: load)
    }

    private func fill(_ template: CPListTemplate, load: @escaping () async -> [Section]?) {
        apply([Section(items: [loadingItem()])], to: template)
        Task { [weak self, weak template] in
            let sections = await load()
            guard let self, let template else { return }
            if let sections {
                self.apply(sections, to: template)
            } else {
                self.apply([Section(items: self.offlineItems { [weak self, weak template] in
                    if let template { self?.fill(template, load: load) }
                })], to: template)
            }
        }
    }

    /// A page of songs with Play, Shuffle and Radio: in the details header where the car supports
    /// one (iOS 26.4), otherwise as the first rows.
    private func pushSongs(_ title: String, load: @escaping () async -> SongPage?) {
        let t = CPListTemplate(title: title, sections: [])
        push(t) { [weak self, weak t] in
            guard let page = await load() else { return nil }
            guard let self, let t else { return [] }
            return self.songPageSections(page, title: title, in: t)
        }
    }

    private func songPageSections(_ page: SongPage, title: String, in template: CPListTemplate) -> [Section] {
        let songs = page.songs
        guard !songs.isEmpty else { return [] }
        let actions: [(String, String, () -> Void)] = [
            (String(localized: "Play"), "play.fill", { [weak self] in self?.play(songs, at: 0, radio: false) }),
            (String(localized: "Shuffle"), "shuffle", { [weak self] in self?.shuffle(songs) }),
            (String(localized: "Radio"), "dot.radiowaves.left.and.right", { [weak self] in
                guard let seed = songs.first(where: { !$0.isLocal }) else { return }
                self?.player.startRadio(from: seed); self?.showNowPlaying()
            }),
        ]
        var sections: [Section] = []
        if #available(iOS 26.4, *) {
            let buttons = actions.prefix(CPListTemplateDetailsHeader.maximumActionButtonCount).map { action -> CPButton in
                let button = CPButton(image: UIImage(systemName: action.1)!) { _ in action.2() }
                button.title = action.0
                return button
            }
            let artwork = page.artwork ?? songs.first?.artwork
            let header = CPListTemplateDetailsHeader(thumbnail: CPThumbnailImage(image: CarPlayArtwork.cached(artwork) ?? CarPlayArtwork.placeholder),
                                                     title: title, subtitle: page.subtitle ?? String(localized: "\(songs.count) songs"),
                                                     actionButtons: Array(buttons))
            header.wantsAdaptiveBackgroundStyle = true
            template.listHeader = header
            Task { [weak header, weak template] in
                guard let image = await CarPlayArtwork.image(artwork), let header, let template else { return }
                header.thumbnail = CPThumbnailImage(image: image)
                template.listHeader = header
            }
        } else if songs.count > 1 {
            let rows = actions.dropFirst().map { action -> CPListItem in
                let item = CPListItem(text: action.0, detailText: nil, image: CarPlayArtwork.symbol(action.1))
                item.handler = { _, completion in action.2(); completion() }
                return item
            }
            sections.append(Section(items: rows))
        }
        sections.append(Section(items: songItems(songs)))
        return sections
    }

    private func openArtist(id: String, name: String) {
        pushSongs(name) {
            guard let page = try? await MusicAPI.artist(id) else { return nil }
            return SongPage(songs: page.topSongs, subtitle: page.subscribers, artwork: page.thumbnail.flatMap { URL(string: $0.upscaledThumbnail()) })
        }
    }

    private func openCollection(_ card: MusicCard) {
        if card.kind == .artist { openArtist(id: card.id, name: card.title); return }
        pushSongs(card.title) {
            guard let page = try? await MusicAPI.collection(card.id) else { return nil }
            return SongPage(songs: page.songs, subtitle: page.subtitle.isEmpty ? nil : page.subtitle,
                            artwork: page.thumbnail.flatMap { URL(string: $0.upscaledThumbnail()) } ?? card.artwork)
        }
    }

    // MARK: Items

    private func songItems(_ songs: [Song]) -> [CPListItem] {
        let limited = Array(songs.prefix(Int(CPListTemplate.maximumItemCount)))
        let currentId = player.current?.id
        return limited.enumerated().map { i, song in
            let item = CPListItem(text: song.title, detailText: song.artist,
                                  image: CarPlayArtwork.cached(song.artwork) ?? CarPlayArtwork.placeholder)
            item.isPlaying = currentId == song.id
            item.playingIndicatorLocation = .trailing
            item.handler = { [weak self] _, completion in self?.play(limited, at: i); completion() }
            loadImage(song.artwork, into: item)
            return item
        }
    }

    private func cardItems(_ cards: [MusicCard]) -> [CPListItem] {
        cards.prefix(Int(CPListTemplate.maximumItemCount)).map { card in
            let item = CPListItem(text: card.title, detailText: card.subtitle,
                                  image: CarPlayArtwork.cached(card.artwork) ?? CarPlayArtwork.placeholder)
            loadImage(card.artwork, into: item)
            if let song = card.song {
                item.handler = { [weak self] _, completion in self?.play([song], at: 0); completion() }
            } else {
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in self?.openCollection(card); completion() }
            }
            return item
        }
    }

    private func loadingItem() -> CPListItem {
        let item = CPListItem(text: String(localized: "Loading…"), detailText: nil)
        item.isEnabled = false
        return item
    }

    /// Shown when YouTube Music can't be reached: try again, or keep driving with the downloads.
    private func offlineItems(retry: @escaping () -> Void) -> [CPListItem] {
        let again = CPListItem(text: String(localized: "Can't reach YouTube Music"), detailText: String(localized: "Tap to try again"),
                               image: CarPlayArtwork.symbol("wifi.exclamationmark", tint: .systemOrange))
        again.handler = { _, completion in retry(); completion() }
        var items = [again]
        let offline = MixBuilder.inputs().offline
        if !offline.isEmpty {
            let play = CPListItem(text: String(localized: "Play your downloads"), detailText: String(localized: "\(offline.count) songs, no signal needed"),
                                  image: CarPlayArtwork.symbol("arrow.down.circle.fill", tint: .systemGreen))
            play.handler = { [weak self] _, completion in self?.shuffle(offline); completion() }
            items.append(play)
        }
        return items
    }

    private func loadImage(_ url: URL?, into item: CPListItem) {
        guard let url, CarPlayArtwork.cached(url) == nil else { return }
        Task { [weak item] in if let image = await CarPlayArtwork.image(url) { item?.setImage(image) } }
    }

    private func loadImages(_ urls: [URL?], into row: CPListImageRowItem) {
        guard urls.contains(where: { $0 != nil && CarPlayArtwork.cached($0) == nil }) else { return }
        let elements = row.elements
        Task { [weak row] in
            for (element, url) in zip(elements, urls) {
                if let image = await CarPlayArtwork.image(url) { element.image = image }
            }
            // Assigning the elements again makes a row on screen reload, once for all the covers.
            row?.elements = elements
        }
    }

    // MARK: Playback

    private func play(_ songs: [Song], at index: Int, radio: Bool? = nil) {
        guard songs.indices.contains(index) else { return }
        player.play(songs, startAt: index, radio: radio ?? (songs.count == 1))
        showNowPlaying()
    }

    private func shuffle(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        player.play(songs, startAt: Int.random(in: 0..<songs.count), shuffled: true)
        showNowPlaying()
    }

    private func alert(_ title: String, message: String) {
        guard let controller = interfaceController else { return }
        let ok = CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak controller] _ in
            controller?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [title, message].filter { !$0.isEmpty }, actions: [ok])
        if controller.presentedTemplate != nil { controller.dismissTemplate(animated: false, completion: nil) }
        controller.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: Now Playing

    private func configureNowPlaying() {
        let np = CPNowPlayingTemplate.shared
        np.add(self)
        np.upNextTitle = String(localized: "Up Next")
        lastButtonState = ""
        refreshNowPlayingButtons()
    }

    private func refreshNowPlayingButtons() {
        let song = player.current
        let liked = song.map(library.isLiked) ?? false
        let sleeping = player.sleepTimerEnd != nil || player.sleepAtEndOfTrack
        let hasUpNext = !player.upNext.isEmpty
        let canOpenAlbum = song?.albumId != nil || song?.artistId != nil
        let state = "\(player.shuffle)\(player.repeatMode)\(liked)\(player.rate)\(sleeping)\(hasUpNext)\(canOpenAlbum)\(song?.isLocal ?? false)"
        guard state != lastButtonState else { return }
        lastButtonState = state
        let np = CPNowPlayingTemplate.shared
        np.isUpNextButtonEnabled = hasUpNext
        np.isAlbumArtistButtonEnabled = canOpenAlbum

        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in self?.player.toggleShuffle(); self?.player.updateNowPlaying() }
        let like = CPNowPlayingImageButton(image: UIImage(systemName: liked ? "heart.fill" : "heart")!) { [weak self] _ in
            guard let self, let song = self.player.current else { return }
            self.library.toggleLike(song)
            self.player.updateNowPlaying()
        }
        let radio = CPNowPlayingImageButton(image: UIImage(systemName: "dot.radiowaves.left.and.right")!) { [weak self] _ in
            guard let self, let song = self.player.current, !song.isLocal else { return }
            self.player.startRadio(from: song)
        }
        radio.isEnabled = song.map { !$0.isLocal } ?? false
        // Shows the speed itself ("1.25×"); each tap moves to the next one.
        let rate = CPNowPlayingImageButton(image: Self.rateImage(player.rate)) { [weak self] _ in
            guard let self else { return }
            let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
            self.player.rate = rates[((rates.firstIndex(of: self.player.rate) ?? 0) + 1) % rates.count]
        }
        // The fifth and last slot: sleep timer and repeat, in a sheet. The moon shows a running timer.
        let more = CPNowPlayingImageButton(image: UIImage(systemName: sleeping ? "moon.zzz.fill" : "ellipsis.circle")!) { [weak self] _ in
            self?.presentMoreSheet()
        }
        np.updateNowPlayingButtons([shuffle, like, radio, rate, more])
    }

    private static func rateImage(_ rate: Float) -> UIImage {
        let text = rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
        let size = CPNowPlayingButtonMaximumImageSize
        let side = min(size.width, size.height) > 0 ? min(size.width, size.height) : 40
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            var pointSize = side * 0.5
            var attributes: [NSAttributedString.Key: Any] = [:]
            var measured = CGSize.zero
            repeat {
                attributes = [.font: UIFont.systemFont(ofSize: pointSize, weight: .bold), .foregroundColor: UIColor.black]
                measured = (text as NSString).size(withAttributes: attributes)
                pointSize -= 1
            } while measured.width > side * 0.95 && pointSize > 8
            (text as NSString).draw(at: CGPoint(x: (side - measured.width) / 2, y: (side - measured.height) / 2), withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private func presentMoreSheet() {
        guard let controller = interfaceController else { return }
        let repeatTitle: String = switch player.repeatMode {
        case .off: String(localized: "Repeat: Off")
        case .all: String(localized: "Repeat: All")
        case .one: String(localized: "Repeat: One")
        }
        let sleepTitle: String
        if let end = player.sleepTimerEnd {
            let minutes = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
            sleepTitle = String(localized: "Sleep timer: \(minutes) min left")
        } else if player.sleepAtEndOfTrack {
            sleepTitle = String(localized: "Sleep timer: end of song")
        } else {
            sleepTitle = String(localized: "Sleep timer")
        }
        let sleep = CPAlertAction(title: sleepTitle, style: .default) { [weak self] _ in
            self?.dismissThen { self?.presentSleepSheet() }
        }
        let repeatAction = CPAlertAction(title: repeatTitle, style: .default) { [weak self] _ in
            self?.player.cycleRepeat()
            self?.dismissThen {}
        }
        let cancel = CPAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in self?.dismissThen {} }
        let sheet = CPActionSheetTemplate(title: player.current?.title, message: nil, actions: [sleep, repeatAction, cancel])
        controller.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func presentSleepSheet() {
        guard let controller = interfaceController else { return }
        var actions = [15, 30, 45, 60].map { minutes in
            CPAlertAction(title: String(localized: "\(minutes) minutes"), style: .default) { [weak self] _ in
                self?.player.setSleepTimer(minutes: minutes)
                self?.dismissThen {}
            }
        }
        actions.append(CPAlertAction(title: String(localized: "End of song"), style: .default) { [weak self] _ in
            self?.player.sleepAtEnd()
            self?.dismissThen {}
        })
        if player.sleepTimerEnd != nil || player.sleepAtEndOfTrack {
            actions.append(CPAlertAction(title: String(localized: "Turn off timer"), style: .destructive) { [weak self] _ in
                self?.player.setSleepTimer(minutes: nil)
                self?.dismissThen {}
            })
        }
        actions.append(CPAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in self?.dismissThen {} })
        let sheet = CPActionSheetTemplate(title: String(localized: "Sleep timer"), message: String(localized: "Pause the music after"), actions: actions)
        controller.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func dismissThen(_ next: @escaping () -> Void) {
        guard let controller = interfaceController, controller.presentedTemplate != nil else { next(); return }
        controller.dismissTemplate(animated: true) { _, _ in
            Task { @MainActor in next() }
        }
    }

    private func showNowPlaying() {
        guard let controller = interfaceController, controller.topTemplate !== CPNowPlayingTemplate.shared else { return }
        controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            let items = player.upNext.prefix(Int(CPListTemplate.maximumItemCount)).map { song -> CPListItem in
                let item = CPListItem(text: song.title, detailText: song.artist,
                                      image: CarPlayArtwork.cached(song.artwork) ?? CarPlayArtwork.placeholder)
                item.handler = { [weak self] _, completion in
                    // The queue may have moved on since this list was built: find the song again.
                    if let self, let offset = self.player.upNext.firstIndex(where: { $0.id == song.id }) {
                        self.player.jump(toUpNext: offset)
                    }
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    completion()
                }
                loadImage(song.artwork, into: item)
                return item
            }
            let t = CPListTemplate(title: String(localized: "Up Next"), sections: [])
            apply([Section(items: Array(items))], to: t)
            t.emptyViewTitleVariants = [String(localized: "Radio")]
            interfaceController?.pushTemplate(t, animated: true, completion: nil)
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            guard let song = player.current else { return }
            if let albumId = song.albumId {
                openCollection(MusicCard(kind: .album, id: albumId, title: song.album ?? song.title, subtitle: song.artist))
            } else if let artistId = song.artistId {
                openArtist(id: artistId, name: song.artist)
            }
        }
    }
}
