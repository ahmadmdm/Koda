import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppState.self) private var app
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("palette") private var palette = Palette.violet.rawValue
    @AppStorage("playerStyle") private var playerStyle = PlayerStyle.classic.rawValue
    @AppStorage("ambientBackground") private var ambient = true
    @AppStorage("homeLayout") private var homeLayout = "mix"
    @AppStorage("musicQuality") private var musicQuality = "high"
    @AppStorage("downloadQuality") private var downloadQuality = "high"
    @AppStorage("normalize") private var normalize = false
    @AppStorage("preload") private var preload = true
    @AppStorage("haptics") private var haptics = "balanced"
    @AppStorage("videoAutoplay") private var videoAutoplay = true
    @AppStorage("sponsorBlock") private var sponsorBlock = true
    @AppStorage("autoSubtitles") private var autoSubtitles = false
    @AppStorage("contentRegion") private var region = Locale.current.region?.identifier ?? "US"
    @AppStorage("contentLanguage") private var language = InnerTube.defaultLanguage
    @State private var query = ""
    @State private var showImporter = false
    @State private var backupURL: URL?
    @State private var confirmClear = false
    @State private var message: String?

    var body: some View {
        Form {
            if matches("account sign in google youtube login حساب تسجيل") { AccountSection() }
            if matches("language arabic english اللغة العربية") {
                Section {
                    LabeledContent("App language", value: Locale.current.localizedString(forLanguageCode: Bundle.main.preferredLocalizations.first ?? "en") ?? "")
                    Button("Change in iOS Settings", systemImage: "globe") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: { Text("Language") } footer: {
                    Text("Choose Arabic or English for Koda in the iOS Settings app; the layout follows the language, right to left for Arabic.")
                }
            }
            if matches("appearance theme dark light color palette accent") {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Colour palette")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Palette.allCases) { p in
                                    Button { palette = p.rawValue } label: {
                                        VStack(spacing: 4) {
                                            Circle()
                                                .fill(p == .artwork ? AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center)) : AnyShapeStyle(p.color.gradient))
                                                .frame(width: 40, height: 40)
                                                .overlay(Circle().stroke(.primary, lineWidth: palette == p.rawValue ? 3 : 0).padding(-4))
                                            Text(p.title).font(.caption2)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                        }
                    }
                    Picker("Home layout", selection: $homeLayout) { Text("Your Mix").tag("mix"); Text("Spotlight").tag("spotlight") }
                    Picker("Haptics", selection: $haptics) {
                        Text("Off").tag("off"); Text("Subtle").tag("subtle"); Text("Balanced").tag("balanced"); Text("Rich").tag("rich")
                    }
                }
            }
            if matches("player style ambient background") {
                Section("Player") {
                    Picker("Player style", selection: $playerStyle) {
                        ForEach(PlayerStyle.allCases) { Label($0.title, systemImage: $0.icon).tag($0.rawValue) }
                    }
                    Toggle("Ambient artwork background", isOn: $ambient)
                }
            }
            if matches("playback quality normalise normalize volume preload stream download") {
                Section {
                    Picker("Streaming quality", selection: $musicQuality) { Text("High (AAC 128 kbps)").tag("high"); Text("Data saver (48 kbps)").tag("low") }
                    Picker("Download quality", selection: $downloadQuality) { Text("High").tag("high"); Text("Saver").tag("saver") }
                    Toggle("Normalise volume", isOn: $normalize)
                    Toggle("Preload upcoming songs", isOn: $preload)
                } header: { Text("Music playback") } footer: { Text("Normalise volume uses the loudness YouTube reports for each song.") }
            }
            if matches("video autoplay sponsorblock sponsor quality subtitles captions") {
                Section {
                    Toggle("Autoplay next video", isOn: $videoAutoplay)
                    Toggle("SponsorBlock", isOn: $sponsorBlock)
                    Toggle("Turn on subtitles automatically", isOn: $autoSubtitles)
                    Picker("Default video quality", selection: Binding(get: { VideoPlayerModel.shared.quality }, set: { VideoPlayerModel.shared.quality = $0 })) {
                        ForEach(VideoQualityCap.allCases) { Text($0.title).tag($0) }
                    }
                } header: { Text("Video") } footer: { Text("SponsorBlock skips sponsored segments using the community database at sponsor.ajay.app.") }
            }
            if matches("content region language country") {
                Section("Content") {
                    Picker("Region", selection: $region) {
                        ForEach(["US", "GB", "SA", "AE", "EG", "KW", "QA", "IN", "DE", "FR", "JP", "KR", "BR", "TR"], id: \.self) { code in
                            Text(Locale.current.localizedString(forRegionCode: code) ?? code).tag(code)
                        }
                    }
                    Picker("Content language", selection: $language) {
                        Text("English").tag("en"); Text("العربية").tag("ar"); Text("Français").tag("fr"); Text("Deutsch").tag("de")
                        Text("Español").tag("es"); Text("Türkçe").tag("tr"); Text("日本語").tag("ja")
                    }
                    NavigationLink(value: Route.hidden) { Text("Hidden & blocked") }
                }
            }
            if matches("storage downloads cache history clear") {
                Section("Storage") {
                    LabeledContent("Downloads", value: ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                    NavigationLink(value: Route.downloads) { Text("Manage downloads") }
                    Button("Clear listening & watch history", role: .destructive) { confirmClear = true }
                }
            }
            if matches("backup restore export import") {
                Section {
                    Button("Back up library…", systemImage: "square.and.arrow.up") {
                        backupURL = try? library.exportBackup()
                    }
                    Button("Restore from backup…", systemImage: "square.and.arrow.down") { showImporter = true }
                } header: { Text("Backup") } footer: {
                    Text("Backups include playlists, likes, saved items, statistics, history, subscriptions and hidden items. Downloaded media is not included.")
                }
            }
            if matches("about version licence license github") {
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Link("Koda on GitHub", destination: URL(string: "https://github.com/Ivorisnoob/Koda")!)
                    Link("Lyrics by LRCLIB", destination: URL(string: "https://lrclib.net")!)
                    Text("Koda is not affiliated with YouTube or Google. Streams are fetched directly from YouTube without an API key.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search settings")
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { library.clearHistory() }
        } message: { Text("Statistics and Recap are built from this history and will start over.") }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                do { try library.importBackup(from: url); app.showToast("Library restored") }
                catch { message = error.localizedDescription }
            }
        }
        .sheet(item: Binding(get: { backupURL.map(IdentifiedURL.init) }, set: { backupURL = $0?.url })) { item in
            ShareLink(item: item.url) { Label("Share backup file", systemImage: "square.and.arrow.up").font(.headline) }
                .buttonStyle(.glassProminent).controlSize(.large)
                .presentationDetents([.height(160)])
        }
        .alert("Restore failed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} } message: { Text(message ?? "") }
    }

    private func matches(_ keywords: String) -> Bool {
        query.isEmpty || keywords.localizedCaseInsensitiveContains(query) || query.split(separator: " ").allSatisfy { keywords.localizedCaseInsensitiveContains($0) }
    }
}

struct IdentifiedURL: Identifiable { var url: URL; var id: String { url.absoluteString } }

/// First-run flow: welcome, then tell Koda your taste once.
struct OnboardingView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var picked: Set<String> = []

    private let artists = ["Taylor Swift", "The Weeknd", "Drake", "Billie Eilish", "Coldplay", "Dua Lipa", "Ed Sheeran", "Bad Bunny",
                           "BTS", "Adele", "Kendrick Lamar", "Arctic Monkeys", "Amr Diab", "Fairuz", "Mohammed Abdu", "Elissa",
                           "Hans Zimmer", "Daft Punk", "Imagine Dragons", "Rihanna", "Bruno Mars", "Lana Del Rey", "Travis Scott", "SZA"]

    var body: some View {
        VStack(spacing: 24) {
            if page == 0 {
                Spacer()
                Image(systemName: "waveform.circle.fill").font(.system(size: 96)).foregroundStyle(.tint).symbolEffect(.variableColor.iterative)
                Text("Welcome to Koda").font(.largeTitle.bold())
                Text("A music and video player powered by YouTube. No account or API key needed — your library, likes and statistics stay on this iPhone.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Spacer()
                Button { withAnimation { page = 1 } } label: { Text("Get Started").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).controlSize(.extraLarge)
            } else {
                Text("Who do you listen to?").font(.title.bold()).padding(.top, 30)
                Text("Pick a few artists and Koda will shape your recommendations.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                ScrollView {
                    FlowLayout(spacing: 10) {
                        ForEach(artists, id: \.self) { a in
                            Button { if picked.contains(a) { picked.remove(a) } else { picked.insert(a) } } label: {
                                Text(a).font(.subheadline.weight(.medium)).padding(.horizontal, 6)
                            }
                            .buttonStyle(picked.contains(a) ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                        }
                    }
                }
                Button {
                    library.data.tasteArtists = Array(picked)
                    dismiss()
                } label: { Text(picked.isEmpty ? "Skip" : "Continue with \(picked.count)").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.extraLarge)
            }
        }
        .padding(28)
        .interactiveDismissDisabled()
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
