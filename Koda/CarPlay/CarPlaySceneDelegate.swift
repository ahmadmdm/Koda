import CarPlay
import MediaPlayer
import UIKit

/// Koda in the car: an audio app with Home, Library, Recents and Explore tabs, and the system
/// Now Playing screen with shuffle, repeat, like, speed and the queue.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var interfaceController: CPInterfaceController?
    private var tabBar: CPTabBarTemplate?
    private var observation: Task<Void, Never>?

    private var player: MusicPlayer { .shared }
    private var library: LibraryStore { .shared }

    // MARK: Connection

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let tabs = CPTabBarTemplate(templates: [homeTab(), libraryTab(), recentsTab(), exploreTab()])
        tabBar = tabs
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        configureNowPlaying()
        Task { await loadHome() }
        Task { await loadExplore() }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CPNowPlayingTemplate.shared.remove(self)
        observation?.cancel()
        self.interfaceController = nil
        tabBar = nil
    }

    // MARK: Tabs

    private func homeTab() -> CPListTemplate {
        let t = CPListTemplate(title: String(localized: "Home"), sections: [CPListSection(items: [loadingItem()])])
        t.tabImage = UIImage(systemName: "house.fill")
        t.emptyViewTitleVariants = [String(localized: "Nothing here yet")]
        return t
    }

    private func libraryTab() -> CPListTemplate {
        let t = CPListTemplate(title: String(localized: "Library"), sections: librarySections())
        t.tabImage = UIImage(systemName: "music.note.square.stack.fill")
        return t
    }

    private func recentsTab() -> CPListTemplate {
        let songs = Array(library.recentSongs.prefix(40))
        let t = CPListTemplate(title: String(localized: "History"), sections: [CPListSection(items: songItems(songs))])
        t.tabImage = UIImage(systemName: "clock.fill")
        t.emptyViewTitleVariants = [String(localized: "No history")]
        return t
    }

    private func exploreTab() -> CPListTemplate {
        let t = CPListTemplate(title: String(localized: "Explore"), sections: [CPListSection(items: [loadingItem()])])
        t.tabImage = UIImage(systemName: "sparkles")
        return t
    }

    private func template(titled key: String) -> CPListTemplate? {
        tabBar?.templates.compactMap { $0 as? CPListTemplate }.first { $0.title == String(localized: String.LocalizationValue(key)) }
    }

    private func loadHome() async {
        var sections: [CPListSection] = []
        // Speed dial: the most played songs, as a grid of artwork.
        let top = library.topSongs(limit: 8).map(\.song)
        if top.count >= 4 {
            let grid = CPListImageRowItem(text: String(localized: "Speed dial"),
                                          gridElements: top.map { _ in CPListImageRowItemGridElement(image: placeholderImage()) },
                                          allowsMultipleLines: false)
            grid.listImageRowHandler = { [weak self] _, index, completion in
                self?.play(top, at: index); completion()
            }
            grid.handler = { [weak self] _, completion in self?.play(top, at: 0); completion() }
            sections.append(CPListSection(items: [grid]))
            Task { [weak grid] in
                var images: [UIImage] = []
                for s in top { images.append(await Self.image(s.artwork) ?? placeholderImage()) }
                grid?.elements = images.map { CPListImageRowItemGridElement(image: $0) }
            }
        }
        if let seed = library.recentSongs.first ?? library.data.likedSongs.first?.song,
           let picks = try? await MusicAPI.radio(for: seed.id) {
            sections.append(CPListSection(items: songItems(Array(picks.filter { $0.id != seed.id }.prefix(12))),
                                          header: String(localized: "Quick picks"), sectionIndexTitle: nil))
        }
        let liked = library.data.likedSongs.prefix(12).map(\.song)
        if !liked.isEmpty {
            sections.append(CPListSection(items: songItems(Array(liked)), header: String(localized: "Liked songs"), sectionIndexTitle: nil))
        }
        if sections.isEmpty, let home = try? await MusicAPI.home(), let shelf = home.shelves.first {
            sections.append(CPListSection(items: cardItems(shelf.items), header: shelf.title, sectionIndexTitle: nil))
        }
        template(titled: "Home")?.updateSections(sections)
    }

    private func loadExplore() async {
        guard let home = try? await MusicAPI.home() else {
            template(titled: "Explore")?.updateSections([])
            return
        }
        let sections = home.shelves.prefix(8).map {
            CPListSection(items: cardItems(Array($0.items.prefix(10))), header: $0.title, sectionIndexTitle: nil)
        }
        template(titled: "Explore")?.updateSections(Array(sections))
    }

    private func librarySections() -> [CPListSection] {
        var rows: [CPListItem] = []
        func folder(_ key: String.LocalizationValue, _ icon: String, count: Int, songs: @escaping () -> [Song]) {
            let item = CPListItem(text: String(localized: key), detailText: "\(count)", image: UIImage(systemName: icon))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushSongs(String(localized: key), songs()); completion()
            }
            rows.append(item)
        }
        folder("Liked songs", "heart.fill", count: library.data.likedSongs.count) { self.library.data.likedSongs.map(\.song) }
        folder("Downloads", "arrow.down.circle.fill", count: library.data.downloads.count) { self.library.data.downloads.map(\.song) }
        var sections = [CPListSection(items: rows)]
        let playlists = library.data.playlists.map { p -> CPListItem in
            let item = CPListItem(text: p.name, detailText: String(localized: "\(p.songs.count) songs"), image: UIImage(systemName: "music.note.list"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in self?.pushSongs(p.name, p.songs); completion() }
            return item
        }
        if !playlists.isEmpty { sections.append(CPListSection(items: playlists, header: String(localized: "Playlists"), sectionIndexTitle: nil)) }
        let saved = library.data.savedCollections + library.data.followedArtists
        if !saved.isEmpty { sections.append(CPListSection(items: cardItems(saved), header: String(localized: "Albums & playlists"), sectionIndexTitle: nil)) }
        return sections
    }

    // MARK: Items

    private func songItems(_ songs: [Song]) -> [CPListItem] {
        let limited = Array(songs.prefix(CPListTemplate.maximumItemCount))
        return limited.enumerated().map { i, song in
            let item = CPListItem(text: song.title, detailText: song.artist, image: placeholderImage())
            item.isPlaying = player.current?.id == song.id
            item.playingIndicatorLocation = .trailing
            item.handler = { [weak self] _, completion in self?.play(limited, at: i); completion() }
            Task { [weak item] in if let image = await Self.image(song.artwork) { item?.setImage(image) } }
            return item
        }
    }

    private func cardItems(_ cards: [MusicCard]) -> [CPListItem] {
        cards.prefix(CPListTemplate.maximumItemCount).map { card in
            let item = CPListItem(text: card.title, detailText: card.subtitle, image: placeholderImage())
            Task { [weak item] in if let image = await Self.image(card.artwork) { item?.setImage(image) } }
            if let song = card.song {
                item.handler = { [weak self] _, completion in self?.player.play([song], radio: true); self?.showNowPlaying(); completion() }
            } else {
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    Task { await self?.openCollection(card) }
                    completion()
                }
            }
            return item
        }
    }

    private func openCollection(_ card: MusicCard) async {
        var songs: [Song] = []
        if card.kind == .artist {
            songs = (try? await MusicAPI.artist(card.id))?.topSongs ?? []
        } else {
            songs = (try? await MusicAPI.collection(card.id))?.songs ?? []
        }
        pushSongs(card.title, songs)
    }

    private func pushSongs(_ title: String, _ songs: [Song]) {
        var sections = [CPListSection(items: songItems(songs))]
        if songs.count > 1 {
            let shuffle = CPListItem(text: String(localized: "Shuffle"), detailText: nil, image: UIImage(systemName: "shuffle"))
            shuffle.handler = { [weak self] _, completion in
                self?.player.play(songs, startAt: Int.random(in: 0..<songs.count), shuffled: true)
                self?.showNowPlaying(); completion()
            }
            sections.insert(CPListSection(items: [shuffle]), at: 0)
        }
        let t = CPListTemplate(title: title, sections: sections)
        t.emptyViewTitleVariants = [String(localized: "Nothing here yet")]
        interfaceController?.pushTemplate(t, animated: true, completion: nil)
    }

    private func play(_ songs: [Song], at index: Int) {
        player.play(songs, startAt: index, radio: songs.count == 1)
        showNowPlaying()
    }

    private func loadingItem() -> CPListItem {
        CPListItem(text: String(localized: "Loading…"), detailText: nil)
    }

    private func placeholderImage() -> UIImage {
        UIImage(systemName: "music.note")!.withTintColor(.systemGray, renderingMode: .alwaysOriginal)
    }

    private static func image(_ url: URL?) async -> UIImage? {
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: Now Playing

    private func configureNowPlaying() {
        let np = CPNowPlayingTemplate.shared
        np.add(self)
        np.isUpNextButtonEnabled = true
        np.upNextTitle = String(localized: "Up Next")
        np.isAlbumArtistButtonEnabled = true
        refreshNowPlayingButtons()
        // Keep the custom buttons in step with the player.
        observation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshNowPlayingButtons()
            }
        }
    }

    private var lastButtonState = ""

    private func refreshNowPlayingButtons() {
        let liked = player.current.map(library.isLiked) ?? false
        let state = "\(player.shuffle)\(player.repeatMode)\(liked)\(player.rate)"
        guard state != lastButtonState else { return }
        lastButtonState = state
        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in self?.player.toggleShuffle(); self?.player.updateNowPlaying() }
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in self?.player.cycleRepeat() }
        let like = CPNowPlayingImageButton(image: UIImage(systemName: liked ? "heart.fill" : "heart")!) { [weak self] _ in
            guard let self, let song = self.player.current else { return }
            self.library.toggleLike(song)
            self.player.updateNowPlaying()
            self.refreshNowPlayingButtons()
        }
        let rate = CPNowPlayingPlaybackRateButton { [weak self] _ in
            guard let self else { return }
            let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
            self.player.rate = rates[((rates.firstIndex(of: self.player.rate) ?? 0) + 1) % rates.count]
        }
        let radio = CPNowPlayingImageButton(image: UIImage(systemName: "dot.radiowaves.left.and.right")!) { [weak self] _ in
            if let song = self?.player.current { self?.player.startRadio(from: song) }
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffle, like, radio, rate, repeatButton])
    }

    private func showNowPlaying() {
        guard let controller = interfaceController, controller.topTemplate !== CPNowPlayingTemplate.shared else { return }
        controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            let upNext = player.upNext
            let items = upNext.prefix(CPListTemplate.maximumItemCount).enumerated().map { i, song -> CPListItem in
                let item = CPListItem(text: song.title, detailText: song.artist, image: placeholderImage())
                item.handler = { [weak self] _, completion in
                    self?.player.jump(toUpNext: i)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    completion()
                }
                Task { [weak item] in if let image = await Self.image(song.artwork) { item?.setImage(image) } }
                return item
            }
            let t = CPListTemplate(title: String(localized: "Up Next"), sections: [CPListSection(items: items)])
            t.emptyViewTitleVariants = [String(localized: "Radio")]
            interfaceController?.pushTemplate(t, animated: true, completion: nil)
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            guard let song = player.current else { return }
            if let albumId = song.albumId {
                Task { await openCollection(MusicCard(kind: .album, id: albumId, title: song.album ?? song.title, subtitle: song.artist)) }
            } else if let artistId = song.artistId {
                Task { await openCollection(MusicCard(kind: .artist, id: artistId, title: song.artist, subtitle: "")) }
            }
        }
    }
}
