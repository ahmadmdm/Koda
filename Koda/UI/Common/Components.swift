import SwiftUI

enum Route: Hashable {
    case album(String), playlist(String), artist(String), localPlaylist(UUID)
    case channel(String), videoPlaylist(String, String)
    case liked, history, stats, downloads, recap, savedCollections, followedArtists
    case videoHistory, watchLater, likedVideos, subscriptionsManage, hidden, accountHistory
}

extension View {
    func kodaDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let id), .playlist(let id): CollectionView(browseId: id)
            case .artist(let id): ArtistView(browseId: id)
            case .localPlaylist(let id): LocalPlaylistView(playlistId: id)
            case .channel(let id): ChannelView(channelId: id)
            case .videoPlaylist(let id, let title): VideoPlaylistView(playlistId: id, title: title)
            case .liked: LikedSongsView()
            case .history: HistoryView()
            case .stats: StatsView()
            case .recap: RecapView()
            case .downloads: DownloadsView()
            case .savedCollections: SavedCollectionsView()
            case .followedArtists: FollowedArtistsView()
            case .videoHistory: VideoListView(kind: .history)
            case .watchLater: VideoListView(kind: .watchLater)
            case .likedVideos: VideoListView(kind: .liked)
            case .subscriptionsManage: ManageSubscriptionsView()
            case .hidden: HiddenItemsView()
            case .accountHistory: AccountHistoryView()
            }
        }
    }
}

extension MusicCard {
    var route: Route? {
        switch kind {
        case .album: .album(id)
        case .playlist: .playlist(id)
        case .artist: .artist(id)
        case .song, .video: nil
        }
    }
}

// MARK: Artwork

struct Artwork: View {
    var url: URL?
    var cornerRadius: CGFloat = 8
    var placeholderIcon = "music.note"

    var body: some View {
        // Color.clear takes exactly the proposed size; the image fills it as an
        // overlay, so a wide image can never widen the layout.
        Color.clear
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default:
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Image(systemName: placeholderIcon).font(.title2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A generated cover for device playlists, in the playlist's own hue.
struct GeneratedCover: View {
    var name: String
    var hue: Double
    var songs: [Song] = []
    var cornerRadius: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            if songs.count >= 4 {
                let side = geo.size.width / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) { tile(0, side); tile(1, side) }
                    HStack(spacing: 0) { tile(2, side); tile(3, side) }
                }
            } else {
                ZStack {
                    LinearGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.85),
                                            Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(name.prefix(1).uppercased())
                        .font(.system(size: geo.size.width * 0.45, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func tile(_ i: Int, _ side: CGFloat) -> some View {
        Artwork(url: songs[i].artwork, cornerRadius: 0).frame(width: side, height: side).clipped()
    }
}

// MARK: Song row

struct SongRow: View {
    var song: Song
    var index: Int? = nil
    var showArtwork = true
    var subtitle: String? = nil
    var action: () -> Void

    @Environment(MusicPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let index, !showArtwork {
                    Text("\(index)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
                }
                if showArtwork {
                    Artwork(url: song.artwork, cornerRadius: 6)
                        .frame(width: 50, height: 50)
                        .overlay {
                            if player.current?.id == song.id {
                                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                                Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                    .foregroundStyle(.white)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.body).lineLimit(1)
                        .foregroundStyle(player.current?.id == song.id ? Color.accentColor : .primary)
                    HStack(spacing: 4) {
                        if downloads.isDownloaded(song.id) {
                            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.tint)
                        }
                        if song.isVideo { Image(systemName: "play.rectangle").font(.caption2).foregroundStyle(.secondary) }
                        Text(subtitle ?? [song.artist, song.duration?.formattedDuration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if library.isLiked(song) { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink) }
                SongMenu(song: song) {
                    Image(systemName: "ellipsis").font(.body).foregroundStyle(.secondary)
                        .frame(width: 32, height: 44).contentShape(Rectangle())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { SongMenuItems(song: song) } preview: {
            VStack(alignment: .leading) {
                Artwork(url: song.artwork, cornerRadius: 12).frame(width: 240, height: 240)
                Text(song.title).font(.headline); Text(song.artist).foregroundStyle(.secondary)
            }.padding()
        }
    }
}

struct SongMenu<Label: View>: View {
    var song: Song
    @ViewBuilder var label: () -> Label
    var body: some View {
        Menu { SongMenuItems(song: song) } label: { label() }
    }
}

struct SongMenuItems: View {
    var song: Song
    @Environment(MusicPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppState.self) private var app

    var body: some View {
        Section {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext([song]) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue([song]) }
            if !song.isLocal {
                Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { player.startRadio(from: song) }
            }
        }
        Section {
            Button(library.isLiked(song) ? "Remove from Liked" : "Like", systemImage: library.isLiked(song) ? "heart.slash" : "heart") {
                library.toggleLike(song)
            }
            Button("Add to Playlist…", systemImage: "text.badge.plus") { app.addToPlaylist = [song] }
            if downloads.isDownloaded(song.id) {
                Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.delete(song.id) }
            } else if !song.isLocal {
                Button("Download", systemImage: "arrow.down.circle") { downloads.download([song]) }
            }
        }
        Section {
            if let artistId = song.artistId { Button("Go to Artist", systemImage: "music.microphone") { app.navigate(.artist(artistId)) } }
            if let albumId = song.albumId { Button("Go to Album", systemImage: "square.stack") { app.navigate(.album(albumId)) } }
            if !song.isLocal {
                ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(song.id)")!) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

// MARK: Cards

struct MusicCardView: View {
    var card: MusicCard
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: card.artwork, cornerRadius: card.kind == .artist ? width / 2 : 12,
                    placeholderIcon: card.kind == .artist ? "person.fill" : "music.note")
                .frame(width: width, height: card.kind == .video ? width * 9 / 16 : width)
            Text(card.title).font(.subheadline.weight(.medium)).lineLimit(1)
                .frame(maxWidth: width, alignment: card.kind == .artist ? .center : .leading)
            Text(card.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: width, alignment: card.kind == .artist ? .center : .leading)
        }
        .frame(width: width)
    }
}

/// Opens a card: plays a song, or pushes a collection.
struct CardLink: View {
    var card: MusicCard
    var context: [MusicCard] = []
    var width: CGFloat = 150
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        if let route = card.route {
            NavigationLink(value: route) { MusicCardView(card: card, width: width) }.buttonStyle(.plain)
        } else if let song = card.song {
            Button {
                let songs = context.compactMap(\.song)
                player.play(songs.isEmpty ? [song] : songs, startAt: songs.firstIndex(of: song) ?? 0, radio: songs.count <= 1)
            } label: { MusicCardView(card: card, width: width) }
            .buttonStyle(.plain)
            .contextMenu { SongMenuItems(song: song) }
        }
    }
}

struct ShelfView: View {
    var shelf: MusicShelf
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.title).font(.title3.bold()).padding(.horizontal)
            if shelf.items.allSatisfy({ $0.kind == .song }) && shelf.items.count > 6 {
                QuickPicksGrid(songs: shelf.items.compactMap(\.song))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(shelf.items) { CardLink(card: $0, context: shelf.items) }
                    }
                    .padding(.horizontal)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
}

/// Rows of songs paged horizontally, four per column.
struct QuickPicksGrid: View {
    var songs: [Song]
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(58), spacing: 6), count: 4), spacing: 16) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                    SongRow(song: song) { player.play(songs, startAt: i) }
                        .containerRelativeFrame(.horizontal) { w, _ in
                            // iPhone: one column and a peek of the next. iPad: as many ~400pt columns as fit.
                            UIDevice.current.userInterfaceIdiom != .pad || w < 600 ? w * 0.86 : w / max(2, (w / 400).rounded(.down)) - 24
                        }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal)
        }
        .scrollTargetBehavior(.viewAligned)
        .frame(height: 4 * 58 + 3 * 6)
    }
}

extension Float {
    /// A playback rate in the user's locale, up to two fraction digits: "1.25×", "١٫٧٥×".
    var speedLabel: String {
        Double(self).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

struct LoadingView: View {
    var body: some View { ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 240) }
}

struct ErrorView: View {
    var message: String
    var retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "wifi.exclamationmark")
        } description: { Text(message) } actions: {
            Button("Try Again", action: retry).buttonStyle(.glassProminent)
        }
    }
}

/// Presents `AddToPlaylistSheet` for `app.addToPlaylist`. Attached to every view that can cover the
/// root (the full-screen player, the queue sheet), with `isActive` false wherever something covers
/// that view, so exactly one presenter shows the sheet.
struct AddToPlaylistPresenter: ViewModifier {
    var isActive: Bool
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { isActive && app.addToPlaylist != nil },
                                           set: { if !$0 { app.addToPlaylist = nil } })) {
            AddToPlaylistSheet(songs: app.addToPlaylist ?? [])
        }
    }
}

extension View {
    func addToPlaylistPresenter(isActive: Bool = true) -> some View {
        modifier(AddToPlaylistPresenter(isActive: isActive))
    }
}

struct AddToPlaylistSheet: View {
    var songs: [Song]
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New playlist", text: $newName)
                        Button("Create") {
                            library.createPlaylist(newName.isEmpty ? String(localized: "My Playlist") : newName, songs: songs)
                            dismiss()
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
                Section("Your playlists") {
                    ForEach(library.data.playlists) { p in
                        Button {
                            library.add(songs, to: p.id); dismiss()
                        } label: {
                            HStack {
                                GeneratedCover(name: p.name, hue: p.coverHue, songs: p.songs, cornerRadius: 6).frame(width: 44, height: 44)
                                VStack(alignment: .leading) {
                                    Text(p.name).foregroundStyle(.primary)
                                    Text("\(p.songs.count) songs").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(songs.count == 1 ? Text("Add to Playlist") : Text("Add \(songs.count) Songs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
