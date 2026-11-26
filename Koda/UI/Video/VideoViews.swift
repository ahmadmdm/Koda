import SwiftUI

struct VideoCard: View {
    var video: Video
    var compact = false
    var queue: [Video] = []
    /// Replaces the views and date line in the compact layout (the downloads list shows quality and size).
    var caption: String? = nil
    @Environment(VideoPlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var app
    @State private var choosingDownload = false

    private var downloads: VideoDownloadManager { .shared }

    var body: some View {
        Button { player.open(video, queue: queue) } label: {
            if compact {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail.frame(width: 168, height: 94)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text(video.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(caption ?? video.metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    thumbnail.aspectRatio(16 / 9, contentMode: .fit)
                    HStack(alignment: .top, spacing: 10) {
                        if let avatar = video.channelAvatar {
                            Artwork(url: URL(string: avatar), cornerRadius: 18, placeholderIcon: "person.fill").frame(width: 36, height: 36)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(video.title).font(.body.weight(.medium)).lineLimit(2)
                            Text([video.channel, video.metaLine].filter { !$0.isEmpty }.joined(separator: " • "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { menu }
        .sheet(isPresented: $choosingDownload) { VideoDownloadSheet(video: video) }
    }

    private var thumbnail: some View {
        Artwork(url: video.thumbnailURL, cornerRadius: compact ? 10 : 16, placeholderIcon: "play.rectangle")
            .overlay(alignment: .bottomTrailing) {
                if video.isLive {
                    Text("LIVE").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white).padding(6)
                } else if let d = video.durationText {
                    Text(d).font(.caption2.weight(.semibold).monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white).padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if downloads.isDownloaded(video.id) {
                    Image(systemName: "arrow.down.circle.fill").font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white).padding(6)
                        .accessibilityLabel("Downloaded")
                }
            }
            .overlay(alignment: .bottom) {
                if let entry = library.data.videoHistory.first(where: { $0.video.id == video.id }),
                   let fraction = WatchProgress.fraction(of: entry) {
                    GeometryReader { g in
                        Rectangle().fill(.red).frame(width: g.size.width * fraction, height: 3)
                    }
                    .frame(height: 3)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: compact ? 10 : 16, bottomTrailingRadius: compact ? 10 : 16))
                }
            }
    }

    @ViewBuilder private var menu: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            if player.playNextInQueue(video) { app.showToast("Playing next") }
        }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
            if player.addToQueue(video) { app.showToast("Added to queue") }
        }
        Button(library.isInWatchLater(video.id) ? "Remove from Watch Later" : "Watch Later", systemImage: "clock") { library.toggleWatchLater(video) }
        Button("Play as Audio", systemImage: "headphones") { MusicPlayer.shared.play([video.asSong], radio: true) }
        Button("Add Audio to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { MusicPlayer.shared.addToQueue([video.asSong]) }
        if let item = downloads.items.first(where: { $0.id == video.id }) {
            VideoExportButtons(item: item)
            Button("Remove Download", systemImage: "trash") { downloads.delete(video.id) }
        } else if downloads.isInProgress(video.id) {
            Button("Cancel Download", systemImage: "xmark.circle") { downloads.cancel(video.id) }
        } else if !video.isLive {
            Button("Download…", systemImage: "arrow.down.circle") { choosingDownload = true }
        }
        if let channelId = video.channelId {
            Button("Go to Channel", systemImage: "person.crop.square") { app.navigate(.channel(channelId)) }
        }
        ShareLink(item: URL(string: "https://youtu.be/\(video.id)")!) { Label("Share", systemImage: "square.and.arrow.up") }
        Divider()
        Button("Not Interested", systemImage: "eye.slash") {
            if !library.data.hiddenVideos.contains(video.id) { library.data.hiddenVideos.append(video.id) }
            app.showToast("Hidden")
        }
        if let channelId = video.channelId {
            Button("Block Channel", systemImage: "hand.raised", role: .destructive) {
                library.hideChannel(ChannelSummary(id: channelId, name: video.channel, avatar: video.channelAvatar))
                app.showToast("Blocked \(video.channel)")
            }
        }
    }
}

struct VideoHomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AccountModel.self) private var account
    @State private var topic = VideoTopic.all[0]
    @State private var videos: [Video] = []
    @State private var loadStamp: LoadStamp?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(VideoTopic.all) { t in
                                Button { topic = t } label: { Label(t.title, systemImage: t.icon).font(.subheadline.weight(.medium)) }
                                    .filterChip(selected: topic == t)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                let continueWatching = WatchProgress.continueWatching(library.data.videoHistory.filter { !library.isHidden($0.video) })
                if topic == VideoTopic.all[0], !continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continue watching").font(.title3.bold()).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(continueWatching) { e in VideoCard(video: e.video).frame(width: 260) }
                            }.padding(.horizontal)
                        }
                    }
                }
                ShortsShelf(source: .search(topic.query.isEmpty ? "trending shorts" : topic.query + " shorts"))
                if loading && videos.isEmpty { LoadingView() }
                if let error, videos.isEmpty { ErrorView(message: error) { Task { await load() } } }
                let visible = library.filtered(videos)
                VideoGrid(videos: visible)
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { ModeSwitcher() } }
        .refreshable { await load() }
        .task(id: "\(topic.id)|\(account.active?.id.uuidString ?? "")") {
            // Back on Home after a channel or playlist: keep the feed (up to four requests) while it is fresh.
            let key = "\(topic.id)|\(account.active?.id.uuidString ?? "")"
            guard loadStamp?.isFresh(for: key) != true else { return }
            await load()
            if !Task.isCancelled, error == nil { loadStamp = LoadStamp(key: key) }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            if topic == VideoTopic.all[0], AccountAPI.isSignedIn, let home = try? await AccountAPI.videoHome(), !home.isEmpty {
                videos = home
            } else {
                videos = try await VideoAPI.feed(topic: topic, seeds: library.data.videoHistory.prefix(3).map(\.video.id))
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { config in AnyView(Button(role: config.role, action: config.trigger) { config.label }.buttonStyle(style)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct VideoSearchView: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @State private var submitted = ""
    @State private var filter: VideoSearchFilter = .all
    @FocusState private var searchFocused: Bool
    @State private var sort: VideoSort = .relevance
    @State private var results: [VideoSearchResult] = []
    @State private var continuation: String?
    @State private var suggestions: [String] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if submitted.isEmpty {
                let items = suggestions.isEmpty ? library.data.videoSearches : suggestions
                ForEach(items, id: \.self) { s in
                    Button { submit(s) } label: {
                        Label(s, systemImage: suggestions.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass").foregroundStyle(.primary)
                    }
                }
                .onDelete { if suggestions.isEmpty { library.data.videoSearches.remove(atOffsets: $0) } }
                if items.isEmpty {
                    ContentUnavailableView("Search YouTube", systemImage: "play.rectangle.on.rectangle", description: Text("Videos, channels and playlists."))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                // The same scrolling glass chips as music search, so the two searches look alike.
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: Spacing.xs) {
                        HStack(spacing: Spacing.xs) {
                            ForEach(VideoSearchFilter.allCases) { f in
                                Button { filter = f } label: { Text(f.title).font(.subheadline.weight(.medium)) }
                                    .filterChip(selected: filter == f)
                            }
                            if filter == .videos {
                                Menu { Picker("Sort", selection: $sort) { ForEach(VideoSort.allCases) { Text($0.title).tag($0) } } } label: {
                                    Image(systemName: "line.3.horizontal.decrease")
                                }
                                .filterChip(selected: false)
                                .accessibilityLabel("Sort")
                            }
                        }
                        .padding(.horizontal, Spacing.m)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: Spacing.xxs, leading: 0, bottom: Spacing.xxs, trailing: 0))
                if loading && results.isEmpty { LoadingView().listRowBackground(Color.clear).listRowSeparator(.hidden) }
                if let error, results.isEmpty { ErrorView(message: error) { Task { await search() } }.listRowSeparator(.hidden) }
                let videos = results.compactMap { if case .video(let v) = $0 { v } else { nil } }
                ForEach(results) { r in
                    switch r {
                    case .video(let v): if !library.isHidden(v) { VideoCard(video: v, compact: true, queue: videos) }
                    case .channel(let c):
                        NavigationLink(value: Route.channel(c.id)) {
                            HStack(spacing: 14) {
                                Artwork(url: c.avatar.flatMap(URL.init(string:)), cornerRadius: 34, placeholderIcon: "person.fill").frame(width: 68, height: 68)
                                VStack(alignment: .leading) { Text(c.name).font(.headline); Text(c.subscribers ?? "").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    case .playlist(let p):
                        NavigationLink(value: Route.videoPlaylist(p.id, p.title)) {
                            HStack(alignment: .top, spacing: 12) {
                                Artwork(url: p.thumbnail.flatMap(URL.init(string:)), cornerRadius: 10, placeholderIcon: "list.bullet.rectangle")
                                    .frame(width: 168, height: 94)
                                    .overlay(alignment: .bottomTrailing) {
                                        if let c = p.count { Text(c).font(.caption2.bold()).padding(4).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white).padding(4) }
                                    }
                                VStack(alignment: .leading) { Text(p.title).font(.subheadline.weight(.medium)).lineLimit(2); Text(p.channel).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if let continuation { ProgressView().frame(maxWidth: .infinity).task(id: continuation) { await loadMore() } }
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Search YouTube")
        .searchFocused($searchFocused)
        .scrollDismissesKeyboard(.immediately)
        // Opening Search with nothing searched yet goes straight to typing.
        .task {
            // After the search field is in the bar; focusing earlier is ignored.
            guard submitted.isEmpty, query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(350))
            searchFocused = true
        }
        .onSubmit(of: .search) { submit(query) }
        .onChange(of: query) { _, new in
            if new.isEmpty { submitted = ""; results = [] }
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard new == query, !new.isEmpty, new != submitted else { suggestions = []; return }
                suggestions = await VideoAPI.suggestions(new)
            }
        }
        .onChange(of: filter) { Task { await search() } }
        .onChange(of: sort) { Task { await search() } }
        .toolbar { ToolbarItem(placement: .principal) { ModeSwitcher() } }
    }

    private func submit(_ raw: String) {
        searchFocused = false
        let q = raw.decodingHTMLEntities
        query = q; submitted = q; suggestions = []
        library.addSearch(q, mode: .video)
        Task { await search() }
    }

    private func search() async {
        guard !submitted.isEmpty else { return }
        loading = true; error = nil; defer { loading = false }
        do { (results, continuation) = try await VideoAPI.search(submitted, filter: filter, sort: sort) }
        catch { self.error = error.localizedDescription; results = [] }
    }

    private func loadMore() async {
        guard let token = continuation else { return }
        if let (more, next) = try? await VideoAPI.search(submitted, filter: filter, continuation: token) {
            let ids = Set(results.map(\.id))
            let fresh = more.filter { !ids.contains($0.id) }
            results += fresh
            // A page that adds nothing new would only bring the same spinner back.
            continuation = fresh.isEmpty ? nil : next
        } else { continuation = nil }
    }
}

struct ChannelView: View {
    var channelId: String
    @Environment(LibraryStore.self) private var library
    @State private var page: ChannelPage?
    @State private var error: String?
    @State private var filter = ""
    @State private var sortNewest = true

    var body: some View {
        Group {
            if let page { content(page) }
            else if let error { ErrorView(message: error) { Task { await load() } } }
            else { LoadingView() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == nil { await load() } }
    }

    private func load() async {
        do { page = try await VideoAPI.channel(channelId); error = nil } catch { self.error = error.localizedDescription }
    }

    private func content(_ page: ChannelPage) -> some View {
        let summary = ChannelSummary(id: page.id, name: page.name, avatar: page.avatar, subscribers: page.subscribers)
        let videos = page.videos.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
        let ordered = sortNewest ? videos : videos.reversed()
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let banner = page.banner {
                    Artwork(url: URL(string: banner), cornerRadius: 16).frame(height: 110).clipped().padding(.horizontal)
                }
                HStack(spacing: 14) {
                    Artwork(url: page.avatar.flatMap(URL.init(string:)), cornerRadius: 40, placeholderIcon: "person.fill").frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.name).font(.title2.bold())
                        Text([page.handle, page.subscribers].compactMap { $0 }.joined(separator: " • ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                if let d = page.description, !d.isEmpty { Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(3).padding(.horizontal) }
                Button { library.toggleSubscription(summary) } label: {
                    Label(library.isSubscribed(page.id) ? "Subscribed" : "Subscribe", systemImage: library.isSubscribed(page.id) ? "bell.fill" : "bell")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(library.isSubscribed(page.id) ? AnyPrimitiveButtonStyle(.glass) : AnyPrimitiveButtonStyle(.glassProminent))
                .controlSize(.large).padding(.horizontal)
                ShortsShelf(source: .channel(page.id))
                HStack {
                    TextField("Search uploads", text: $filter).textFieldStyle(.roundedBorder)
                    Button { sortNewest.toggle() } label: { Label(sortNewest ? "Newest" : "Oldest", systemImage: "arrow.up.arrow.down") }.buttonStyle(.glass)
                }
                .padding(.horizontal)
                VideoGrid(videos: Array(ordered), spacing: 20)
            }
            .padding(.vertical)
        }
    }
}

struct VideoPlaylistView: View {
    var playlistId: String
    var title: String
    @State private var videos: [Video] = []
    @State private var loadedTitle: String?
    @State private var error: String?
    @State private var loaded = false
    @Environment(VideoPlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        List {
            if !videos.isEmpty {
                Button { player.playAll(library.filtered(videos)) } label: { Label("Play all", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).controlSize(.large).listRowBackground(Color.clear)
            }
            ForEach(videos) { VideoCard(video: $0, compact: true, queue: videos) }
            if let error { ErrorView(message: error) { Task { await load() } } }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .overlay {
            if videos.isEmpty && error == nil {
                if loaded { ContentUnavailableView("No videos", systemImage: "list.bullet.rectangle", description: Text("This playlist is empty.")) }
                else { LoadingView() }
            }
        }
        .navigationTitle(loadedTitle ?? title)
        .task { if !loaded { await load() } }
    }

    private func load() async {
        do { (loadedTitle, videos) = try await VideoAPI.playlist(playlistId); error = nil } catch { self.error = error.localizedDescription }
        loaded = true
    }
}

struct SubscriptionsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AccountModel.self) private var account
    @State private var feed: [Video] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var loadStamp: LoadStamp?
    @State private var channelFilter: String?
    @State private var maxAgeDays = 0
    /// When each feed video went up: RSS's exact date, else worked out from the account feed's
    /// "3 hours ago".
    @State private var dates: [String: Date] = [:]

    /// The device's follows and the active account's channels.
    private var follows: [ChannelSummary] { library.subscriptions(for: account.active) }

    var body: some View {
        let follows = follows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !follows.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(follows) { c in
                                Button { channelFilter = channelFilter == c.id ? nil : c.id } label: {
                                    VStack {
                                        Artwork(url: c.avatar.flatMap(URL.init(string:)), cornerRadius: 30, placeholderIcon: "person.fill").frame(width: 60, height: 60)
                                            .overlay(Circle().stroke(.tint, lineWidth: channelFilter == c.id ? 3 : 0))
                                        Text(c.name).font(.caption2).lineLimit(1).frame(width: 66)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                let visible = Self.filter(feed, channel: channelFilter, maxAgeDays: maxAgeDays, dates: dates)
                VideoGrid(videos: visible, spacing: 20)
                if loading && feed.isEmpty { LoadingView() }
                if !loading && loaded && hasFollows {
                    // Every channel's feed normally has uploads, so an empty feed means they all failed.
                    if feed.isEmpty {
                        ErrorView(message: String(localized: "Couldn't load your subscriptions. Check your connection and try again.")) { Task { await load() } }
                    } else if visible.isEmpty {
                        ContentUnavailableView("No videos", systemImage: "line.3.horizontal.decrease.circle", description: Text("Nothing matches these filters."))
                    }
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if !hasFollows {
                ContentUnavailableView("No subscriptions", systemImage: "rectangle.stack.badge.person.crop", description: Text("Subscribe to channels from their page. Follows stay on this iPhone."))
            }
        }
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Uploaded", selection: $maxAgeDays) {
                        Text("Any time").tag(0); Text("Today").tag(1); Text("This week").tag(7); Text("This month").tag(30)
                    }
                    NavigationLink(value: Route.subscriptionsManage) { Label("Manage", systemImage: "person.2") }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel("Filter")
            }
        }
        .refreshable { await load() }
        .onChange(of: account.active?.id) { channelFilter = nil }
        .task(id: "\(follows.count)|\(account.active?.id.uuidString ?? "")") {
            // One RSS request per followed channel: don't send them all again on every return to this tab.
            let key = "\(follows.count)|\(account.active?.id.uuidString ?? "")"
            guard loadStamp?.isFresh(for: key) != true else { return }
            await load()
            if !Task.isCancelled, !feed.isEmpty { loadStamp = LoadStamp(key: key) }
        }
    }

    private var hasFollows: Bool { !follows.isEmpty || account.isSignedIn }

    /// The feed narrowed to one channel and to uploads newer than `maxAgeDays` (0: any time).
    /// A video whose date is unknown is left out once an age is chosen.
    static func filter(_ feed: [Video], channel: String?, maxAgeDays: Int, dates: [String: Date], now: Date = .now) -> [Video] {
        let cutoff = maxAgeDays > 0 ? Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: now) : nil
        return feed.filter { v in
            guard channel == nil || v.channelId == channel else { return false }
            guard let cutoff else { return true }
            guard let date = dates[v.id] ?? v.publishedDate else { return false }
            return date >= cutoff
        }
    }

    private func load() async {
        loading = true; defer { loading = false; loaded = true }
        let follows = follows
        let ids = follows.map(\.id)
        let avatars = Dictionary(follows.map { ($0.id, $0.avatar) }, uniquingKeysWith: { a, _ in a })
        var all: [Video] = []
        await withTaskGroup(of: [Video].self) { group in
            for id in ids { group.addTask { await VideoAPI.rssFeed(channelId: id) } }
            if AccountAPI.isSignedIn { group.addTask { (try? await AccountAPI.subscriptionsFeed()) ?? [] } }
            for await vids in group { all += vids }
        }
        var seen = Set<String>()
        all = all.filter { seen.insert($0.id).inserted }
        feed = library.filtered(all.map { var v = $0; v.channelAvatar = v.channelAvatar ?? v.channelId.flatMap { avatars[$0] ?? nil }; return v })

        // The account feed arrives newest-first without dates and keeps YouTube's order; device-only
        // follows from RSS carry dates and follow it, newest first.
        feed = feed.filter { $0.publishedDate == nil }
            + feed.filter { $0.publishedDate != nil }.sorted { $0.publishedDate! > $1.publishedDate! }
        let now = Date.now
        dates = Dictionary(feed.compactMap { v in (v.publishedDate ?? PublishedDate.parse(v.published, now: now)).map { (v.id, $0) } },
                           uniquingKeysWith: { a, _ in a })
    }
}

struct ManageSubscriptionsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AccountModel.self) private var account
    var body: some View {
        let follows = library.subscriptions(for: account.active)
        List {
            ForEach(follows) { c in
                NavigationLink(value: Route.channel(c.id)) {
                    HStack {
                        Artwork(url: c.avatar.flatMap(URL.init(string:)), cornerRadius: 20, placeholderIcon: "person.fill").frame(width: 40, height: 40)
                        Text(c.name)
                    }
                }
            }
            .onDelete { idx in idx.map { follows[$0].id }.forEach { library.unsubscribe($0) } }
        }
        .navigationTitle("Subscriptions")
        .toolbar { EditButton() }
    }
}

struct HiddenItemsView: View {
    @Environment(LibraryStore.self) private var library
    var body: some View {
        List {
            Section("Blocked channels") {
                ForEach(library.data.hiddenChannels) { Text($0.name) }.onDelete { library.data.hiddenChannels.remove(atOffsets: $0) }
            }
            Section("Hidden videos") {
                Text("\(library.data.hiddenVideos.count) videos hidden")
                if !library.data.hiddenVideos.isEmpty { Button("Unhide all") { library.data.hiddenVideos.removeAll() } }
            }
        }
        .navigationTitle("Hidden")
    }
}

enum VideoListKind { case history, watchLater, liked }

struct VideoListView: View {
    var kind: VideoListKind
    @Environment(LibraryStore.self) private var library
    var body: some View {
        let entries: [VideoEntry] = switch kind {
        case .history: library.data.videoHistory
        case .watchLater: library.data.watchLater
        case .liked: library.data.likedVideos
        }
        let videos = entries.map(\.video)
        List {
            ForEach(videos) { VideoCard(video: $0, compact: true, queue: videos) }
                .onDelete { idx in
                    switch kind {
                    case .history: library.data.videoHistory.remove(atOffsets: idx)
                    case .watchLater: library.data.watchLater.remove(atOffsets: idx)
                    case .liked: library.data.likedVideos.remove(atOffsets: idx)
                    }
                }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .overlay { if videos.isEmpty { ContentUnavailableView("Nothing here yet", systemImage: "play.rectangle") } }
        .navigationTitle(kind == .history ? Text("History") : kind == .watchLater ? Text("Watch Later") : Text("Liked videos"))
    }
}

struct VideoLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AccountModel.self) private var account
    var body: some View {
        List {
            if account.isSignedIn {
                Section {
                    NavigationLink(value: Route.videoPlaylist("WL", String(localized: "Watch Later"))) { Label("Watch Later", systemImage: "clock.badge.checkmark") }
                    NavigationLink(value: Route.videoPlaylist("LL", String(localized: "Liked videos"))) { Label("Liked videos", systemImage: "hand.thumbsup") }
                    NavigationLink(value: Route.accountHistory) { Label("Watch history", systemImage: "clock.arrow.circlepath") }
                } header: { Label(account.active?.name ?? "YouTube", systemImage: "person.crop.circle") }
            }
            Section {
                link(.videoHistory, "History", "clock.fill", .orange, library.data.videoHistory.count)
                link(.watchLater, "Watch Later", "clock.badge.checkmark.fill", .blue, library.data.watchLater.count)
                link(.likedVideos, "Liked videos", "hand.thumbsup.fill", .pink, library.data.likedVideos.count)
                link(.videoDownloads, "Downloads", "arrow.down.circle.fill", .indigo, VideoDownloadManager.shared.items.count)
                link(.subscriptionsManage, "Subscriptions", "person.2.fill", .green, library.subscriptions(for: account.active).count)
                link(.hidden, "Hidden & blocked", "eye.slash.fill", .gray, library.data.hiddenChannels.count + library.data.hiddenVideos.count)
            }
            if !library.data.videoHistory.isEmpty {
                Section("Recently watched") {
                    ForEach(library.data.videoHistory.prefix(10)) { VideoCard(video: $0.video, compact: true) }
                }
            }
        }
        .readableContentWidth()
        .navigationTitle("Library")
        .toolbar { ToolbarItem(placement: .principal) { ModeSwitcher() } }
    }

    private func link(_ route: Route, _ title: LocalizedStringKey, _ icon: String, _ color: Color, _ count: Int) -> some View {
        NavigationLink(value: route) {
            HStack {
                Label { Text(title) } icon: {
                    Image(systemName: icon).foregroundStyle(.white).frame(width: 30, height: 30).background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
                // No "0": in Arabic its digit (٠) reads as a stray dot.
                if count > 0 { Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
    }
}

/// The account's YouTube watch history.
struct AccountHistoryView: View {
    @State private var videos: [Video] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        List { ForEach(videos) { VideoCard(video: $0, compact: true, queue: videos) } }
            .listStyle(.plain)
            .readableContentWidth()
            .overlay {
                if loading { LoadingView() }
                else if let error, videos.isEmpty { ErrorView(message: error) { Task { await load() } } }
                else if videos.isEmpty { ContentUnavailableView("Nothing here yet", systemImage: "clock") }
            }
            .navigationTitle("Watch history")
            .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { videos = try await AccountAPI.watchHistory(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
