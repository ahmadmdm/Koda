import SwiftUI
import Speech

struct MusicSearchView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var submitted = ""
    @FocusState private var searchFocused: Bool
    @State private var filter: MusicSearchFilter = .songs
    @State private var results: [MusicCard] = []
    @State private var continuation: String?
    @State private var suggestions: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var voice = VoiceSearch()

    var body: some View {
        List {
            if submitted.isEmpty {
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions, id: \.self) { s in
                            Button { submit(s) } label: { Label(s, systemImage: "magnifyingglass").foregroundStyle(.primary) }
                        }
                    }
                } else if !library.data.musicSearches.isEmpty {
                    Section {
                        ForEach(library.data.musicSearches, id: \.self) { s in
                            Button { submit(s) } label: { Label(s, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary) }
                        }
                        .onDelete { library.data.musicSearches.remove(atOffsets: $0) }
                    } header: {
                        HStack { Text("Recent"); Spacer(); Button("Clear") { library.data.musicSearches.removeAll() }.font(.caption) }
                    }
                } else {
                    ContentUnavailableView("Search YouTube Music", systemImage: "music.magnifyingglass",
                                           description: Text("Songs, albums, artists, playlists and videos."))
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    // Scrolling chips rather than a segmented picker, so longer labels (Arabic) never truncate.
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(MusicSearchFilter.allCases) { f in
                                    Button { filter = f } label: { Text(f.title).font(.subheadline.weight(.medium)) }
                                        .buttonStyle(filter == f ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                                        .accessibilityAddTraits(filter == f ? .isSelected : [])
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                if loading && results.isEmpty { LoadingView().listRowBackground(Color.clear) }
                if let error, results.isEmpty { ErrorView(message: error) { Task { await search() } }.listRowBackground(Color.clear) }
                Section {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, card in
                        resultRow(card, index: i)
                    }
                    if let continuation {
                        ProgressView().frame(maxWidth: .infinity).task(id: continuation) { await loadMore() }
                    }
                }
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Songs, artists, albums")
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
                suggestions = await MusicAPI.suggestions(new)
            }
        }
        .onChange(of: filter) { Task { await search() } }
        .onChange(of: app.searchRequest, initial: true) { _, request in
            guard let request else { return }
            app.searchRequest = nil
            submit(request)
        }
        .onChange(of: voice.transcript) { _, t in if !t.isEmpty { query = t } }
        .onChange(of: voice.isRecording) { _, rec in if !rec, !voice.transcript.isEmpty { submit(voice.transcript) } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { voice.toggle() } label: {
                    Image(systemName: voice.isRecording ? "mic.fill" : "mic").symbolEffect(.pulse, isActive: voice.isRecording)
                }
                .accessibilityLabel(voice.isRecording ? "Stop Voice Search" : "Voice Search")
            }
            ToolbarItem(placement: .topBarLeading) { ModeSwitcher() }
        }
    }

    @ViewBuilder private func resultRow(_ card: MusicCard, index: Int) -> some View {
        if let song = card.song {
            SongRow(song: song, subtitle: card.subtitle) {
                player.play([song], radio: true)
            }
        } else if let route = card.route {
            NavigationLink(value: route) {
                HStack(spacing: 12) {
                    Artwork(url: card.artwork, cornerRadius: card.kind == .artist ? 25 : 6,
                            placeholderIcon: card.kind == .artist ? "person.fill" : "square.stack")
                        .frame(width: 50, height: 50)
                    VStack(alignment: .leading) {
                        Text(card.title).lineLimit(1)
                        Text(card.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func submit(_ q: String) {
        searchFocused = false
        query = q
        submitted = q
        suggestions = []
        library.addSearch(q, mode: .music)
        Task { await search() }
    }

    private func search() async {
        guard !submitted.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let (items, next) = try await MusicAPI.search(submitted, filter: filter)
            results = items; continuation = next
        } catch { self.error = error.localizedDescription; results = [] }
    }

    private func loadMore() async {
        guard let token = continuation else { return }
        if let (items, next) = try? await MusicAPI.search(submitted, filter: filter, continuation: token) {
            let ids = Set(results.map(\.id))
            let fresh = items.filter { !ids.contains($0.id) }
            results += fresh
            // A page that adds nothing new would only bring the same spinner back.
            continuation = fresh.isEmpty ? nil : next
        } else { continuation = nil }
    }
}

/// On-device speech recognition for voice search.
@MainActor
@Observable
final class VoiceSearch {
    var transcript = ""
    var isRecording = false
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?

    func toggle() { isRecording ? stop() : start() }

    func start() {
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            Task { @MainActor in
                guard status == .authorized else { return }
                AVAudioApplication.requestRecordPermission { @Sendable granted in
                    Task { @MainActor in if granted { self.begin() } }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return }
        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try? session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.removeTap(onBus: 0)
        Self.installTap(on: input, format: format, request: request)
        engine.prepare()
        guard (try? engine.start()) != nil else { return }
        isRecording = true
        task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                if let text { self.transcript = text }
                if final || error != nil { self.stop() }
            }
        }
        Task { try? await Task.sleep(for: .seconds(6)); if self.isRecording { self.stop() } }
    }

    /// The tap runs on the audio render thread, so it is built outside the main actor.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest) {
        input.removeTap(onBus: 0)
        let sink = BufferSink(request: request)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in sink.append(buffer) }
    }

    /// Hands tap buffers to the recognition request from the audio thread. Speech documents
    /// `append(_:)` as callable from any thread; the request is not marked Sendable, so the
    /// guarantee is stated here once instead of importing the whole module as `@preconcurrency`.
    nonisolated private final class BufferSink: @unchecked Sendable {
        private let request: SFSpeechAudioBufferRecognitionRequest
        init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
        func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        isRecording = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }
}
