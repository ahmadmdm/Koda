import SwiftUI
import AVFoundation
import Observation

/// Polls a live chat, or plays a finished stream's chat back in step with the video.
@MainActor
@Observable
final class LiveChatModel {
    private(set) var messages: [LiveChatMessage] = []
    private(set) var isLoading = true
    private(set) var error: String?

    @ObservationIgnored private var seen = Set<String>()
    private let limit = 400

    /// Runs until the calling task is cancelled (the panel's `.task` ends when it disappears).
    func run(_ source: LiveChatSource, playerTime: @escaping () -> Double) async {
        messages = []; seen = []; isLoading = true; error = nil
        if source.isReplay { await replay(source, playerTime: playerTime) } else { await live(source) }
    }

    private func live(_ source: LiveChatSource) async {
        var token: String? = source.continuation
        while let current = token, !Task.isCancelled {
            do {
                let page = try await LiveChatAPI.live(current)
                guard !Task.isCancelled else { return }
                apply(page.messages, removed: page.removedIds)
                error = nil
                token = page.next
                // The server asks for ~10s between polls; a few seconds keeps chat lively.
                let wait = min(max(Double(page.timeoutMs) / 1000, 2), 5)
                try await Task.sleep(for: .seconds(wait))
            } catch is CancellationError {
                return
            } catch {
                if messages.isEmpty { self.error = error.localizedDescription }
                isLoading = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Replay windows hold a few minutes each; messages are released as the player reaches them,
    /// and a seek outside the loaded window restarts from the seek token.
    private func replay(_ source: LiveChatSource, playerTime: @escaping () -> Double) async {
        var pending: [LiveChatMessage] = []
        var next: String?
        var seek: String? = nil
        var windowStart = 0, windowEnd = -1
        var lastTime = -1
        var fetching = false

        func load(_ token: String, at ms: Int, reset: Bool) async {
            fetching = true; defer { fetching = false }
            guard let page = try? await LiveChatAPI.replay(token, offsetMs: ms), !Task.isCancelled else { return }
            if reset { messages = []; seen = []; pending = []; windowStart = ms }
            seek = page.seek ?? seek
            next = page.next
            let queued = Set(pending.map(\.id))
            let fresh = page.messages.filter { !seen.contains($0.id) && !queued.contains($0.id) }
            pending = (pending + fresh).sorted { ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0) }
            windowEnd = max(windowEnd, page.messages.compactMap(\.offsetMs).max() ?? ms)
            if page.messages.isEmpty { next = nil }
            isLoading = false
        }

        await load(source.continuation, at: Int(playerTime() * 1000), reset: true)
        while !Task.isCancelled {
            let t = Int(playerTime() * 1000)
            let jumped = lastTime >= 0 && (t < lastTime - 3000 || t > lastTime + 30_000)
            if jumped || t < windowStart - 3000 || (windowEnd >= 0 && t > windowEnd + 30_000) {
                windowEnd = -1
                await load(seek ?? source.continuation, at: t, reset: true)
            } else if !fetching, let token = next, t > windowEnd - 15_000 {
                await load(token, at: t, reset: false)
            }
            lastTime = t
            let due = pending.prefix { ($0.offsetMs ?? 0) <= t }
            if !due.isEmpty {
                pending.removeFirst(due.count)
                apply(Array(due), removed: [])
            }
            try? await Task.sleep(for: .seconds(0.5))
        }
    }

    private func apply(_ new: [LiveChatMessage], removed: Set<String>) {
        isLoading = false
        var list = messages
        if !removed.isEmpty { list.removeAll { removed.contains($0.id) } }
        for m in new where seen.insert(m.id).inserted { list.append(m) }
        if list.count > limit { list.removeFirst(list.count - limit) }
        messages = list
    }
}

/// The chat panel shown under the player on the watch page.
struct LiveChatPanel: View {
    var source: LiveChatSource
    var onClose: () -> Void
    @Environment(VideoPlayerModel.self) private var player
    @State private var model = LiveChatModel()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var pinned = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(source.isReplay ? "Chat replay" : "Live chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 32, height: 32) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel("Close chat")
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.messages) { LiveChatRow(message: $0) }
                }
                .padding(.horizontal).padding(.vertical, 10)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
            } action: { _, atBottom in pinned = atBottom }
            .onChange(of: model.messages.last?.id) {
                if pinned { withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) } }
            }
            .overlay {
                if model.messages.isEmpty {
                    if model.isLoading { ProgressView() }
                    else if let error = model.error { Text(error).font(.callout).foregroundStyle(.secondary).padding() }
                    else { Text(source.isReplay ? "No chat at this point" : "Waiting for messages…").font(.callout).foregroundStyle(.secondary) }
                }
            }
            .overlay(alignment: .bottom) {
                if !pinned {
                    Button { pinned = true; withAnimation { position.scrollTo(edge: .bottom) } } label: {
                        Label("Latest", systemImage: "arrow.down").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass).padding(8)
                }
            }
        }
        .background(Color(.systemBackground))
        .task(id: source) {
            let avPlayer = player.player
            await model.run(source) { avPlayer.currentTime().seconds.isFinite ? avPlayer.currentTime().seconds : 0 }
        }
    }
}

struct LiveChatRow: View {
    var message: LiveChatMessage

    var body: some View {
        switch message.kind {
        case .system:
            Text(verbatim: message.text).font(.caption).foregroundStyle(.secondary)
        case .superChat, .membership:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: message.author).font(.caption.weight(.semibold)).lineLimit(1)
                        if let amount = message.amount { Text(verbatim: amount).font(.subheadline.bold()) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(color(message.headerColor) ?? (message.kind == .membership ? .green.opacity(0.8) : .orange))
                if !message.text.isEmpty {
                    Text(verbatim: message.text).font(.subheadline)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(color(message.bodyColor) ?? (message.kind == .membership ? .green.opacity(0.55) : .orange.opacity(0.75)))
                }
            }
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .text:
            HStack(alignment: .top, spacing: 8) {
                avatar
                Text(line).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var avatar: some View {
        Artwork(url: message.authorPhoto.flatMap(URL.init(string:)), cornerRadius: 12, placeholderIcon: "person.fill")
            .frame(width: 24, height: 24)
    }

    private var line: AttributedString {
        var name = AttributedString(message.author)
        name.font = .subheadline.weight(.semibold)
        switch message.role {
        case .owner: name.foregroundColor = .orange
        case .moderator: name.foregroundColor = .blue
        case .member: name.foregroundColor = .green
        case .viewer: name.foregroundColor = .secondary
        }
        return name + AttributedString("  " + message.text)
    }

    private func color(_ argb: UInt32?) -> Color? {
        guard let argb else { return nil }
        return Color(.sRGB, red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
                     blue: Double(argb & 0xFF) / 255, opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}
