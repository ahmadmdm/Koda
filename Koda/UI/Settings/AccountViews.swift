import Observation
import SwiftUI
import WebKit

/// Main-actor mirror of `AccountSession` for the interface.
@MainActor
@Observable
final class AccountModel {
    static let shared = AccountModel()
    var accounts: [YouTubeAccount] = []
    var active: YouTubeAccount?
    var showSignIn = false
    var pendingSignOut: YouTubeAccount?

    private init() {
        reload()
        NotificationCenter.default.addObserver(forName: AccountSession.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AccountModel.shared.reload() }
        }
        if active != nil {
            // Off the launch path: Home's own requests go first.
            Task(priority: .utility) {
                try? await Task.sleep(for: .seconds(3))
                await AccountAPI.refreshProfile()
                await importSubscriptions()
            }
        }
    }

    func reload() {
        let previous = active?.id
        // Google rotates session cookies on many responses, and each rotation posts a change. No view
        // shows cookies: assign only when something else differs, so the screens reading the account
        // (Home among them) don't redraw after every signed-in request.
        let all = AccountSession.shared.all, current = AccountSession.shared.active
        func shown(_ a: YouTubeAccount?) -> YouTubeAccount? { a.map { var a = $0; a.cookies = ""; return a } }
        if all.map(shown) != accounts.map(shown) { accounts = all }
        if shown(current) != shown(active) { active = current }
        if let id = active?.id, id != previous { Task { await importSubscriptions() } }
    }

    /// Adds the account's channels to the device's follows, so subscribe buttons show the account's
    /// state. Nothing is removed: device-only follows never needed an account.
    private func importSubscriptions() async {
        guard let channels = try? await AccountAPI.subscribedChannels(), !channels.isEmpty else { return }
        let library = LibraryStore.shared
        let known = Set(library.data.subscriptions.map(\.id))
        let added = channels.filter { !known.contains($0.id) }
        // Usually nothing is new: leave the library (and its save and redraw) alone then.
        if !added.isEmpty { library.data.subscriptions += added }
    }

    var isSignedIn: Bool { active != nil }
}

// MARK: Sign-in

/// Google's own sign-in page in an embedded browser. When it lands on music.youtube.com the
/// session is read from the **music.youtube.com** cookie jar specifically: mid-login pages sit on
/// accounts.google.com, whose jar also has a SAPISID, and saving that one gives a signed-in-looking
/// session that YouTube treats as anonymous.
struct GoogleSignInView: View {
    var onDone: (Bool) -> Void
    @State private var loading = true
    @State private var showPaste = false

    var body: some View {
        NavigationStack {
            SignInWebView(loading: $loading) { cookies in
                AccountSession.shared.signIn(cookies: cookies)
                Task { await AccountAPI.refreshProfile() }
                onDone(true)
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay { if loading { ProgressView().controlSize(.large) } }
            .navigationTitle("Sign in to YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { onDone(false) } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Paste session cookies…", systemImage: "doc.on.clipboard") { showPaste = true }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .sheet(isPresented: $showPaste) { PasteCookiesView { ok in showPaste = false; if ok { onDone(true) } } }
        }
    }
}

struct SignInWebView: UIViewRepresentable {
    @Binding var loading: Bool
    var onSession: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A fresh, non-persistent store: Google's page continues as whoever a jar already holds,
        // so adding a second account must never start from the first one's cookies.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        // Present as Mobile Safari, which Google's sign-in supports.
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
        web.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://music.youtube.com")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SignInWebView
        private var finished = false
        init(_ parent: SignInWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            guard !finished, let host = webView.url?.host, host.hasSuffix("youtube.com") else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                // Exactly the cookies music.youtube.com would receive: its own and .youtube.com's.
                let forMusic = cookies.filter { c in
                    let domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                    return "music.youtube.com".hasSuffix(domain)
                }
                let header = forMusic.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                guard AccountSession.missingRequired(header).isEmpty else { return }
                self.finished = true
                self.parent.onSession(header)
            }
        }
    }
}

/// Fallback from the Android app: paste a `Cookie` header copied from a signed-in browser.
struct PasteCookiesView: View {
    var onDone: (Bool) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 160).font(.footnote.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Copy the Cookie header of a request to music.youtube.com from a browser where you are signed in. It must contain SAPISID and SID. The session is stored in the Keychain on this iPhone only.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Session cookies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(false) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cookies = AccountSession.normalize(text)
                        let missing = AccountSession.missingRequired(cookies)
                        guard missing.isEmpty else {
                            error = String(localized: "Missing: \(missing.joined(separator: ", "))")
                            return
                        }
                        AccountSession.shared.signIn(cookies: cookies)
                        Task { await AccountAPI.refreshProfile() }
                        onDone(true)
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}

// MARK: Settings section

struct AccountSection: View {
    @Environment(AccountModel.self) private var account

    var body: some View {
        Section {
            if let active = account.active {
                HStack(spacing: 12) {
                    Artwork(url: active.avatar.flatMap(URL.init(string:)), cornerRadius: 24, placeholderIcon: "person.fill")
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active.name ?? String(localized: "YouTube account")).font(.headline)
                        if let handle = active.handle { Text(handle).font(.subheadline).foregroundStyle(.secondary) }
                        if active.expired {
                            Label("Session expired. Sign in again.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                ForEach(account.accounts.filter { $0.id != active.id }) { other in
                    Button { AccountSession.shared.switchTo(other.id) } label: {
                        Label(other.name ?? String(localized: "YouTube account"), systemImage: "arrow.left.arrow.right")
                    }
                }
                Button("Add another account", systemImage: "person.badge.plus") { account.showSignIn = true }
                if active.expired { Button("Sign in again", systemImage: "arrow.clockwise") { account.showSignIn = true } }
                Button("Use without an account", systemImage: "person.crop.circle.badge.xmark") { AccountSession.shared.switchTo(nil) }
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { account.pendingSignOut = active }
            } else {
                if !account.accounts.isEmpty {
                    ForEach(account.accounts) { a in
                        Button { AccountSession.shared.switchTo(a.id) } label: {
                            Label(a.name ?? String(localized: "YouTube account"), systemImage: "person.crop.circle")
                        }
                    }
                }
                Button { account.showSignIn = true } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Optional. Signing in adds your YouTube and YouTube Music home, library, liked songs, subscriptions and history, and syncs likes, saves and subscriptions back to YouTube. Without an account everything else keeps working on this iPhone.")
        }
    }
}

/// Sign-in and sign-out presentation, attached at the root so any screen can ask for it.
struct AccountPresenter: ViewModifier {
    @Environment(AccountModel.self) private var account

    func body(content: Content) -> some View {
        @Bindable var account = account
        content
            .fullScreenCover(isPresented: $account.showSignIn) { GoogleSignInView { _ in account.showSignIn = false } }
            .confirmationDialog("Sign out of this account?", isPresented: Binding(get: { account.pendingSignOut != nil }, set: { if !$0 { account.pendingSignOut = nil } }), titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { if let a = account.pendingSignOut { AccountSession.shared.signOut(a.id) } }
            } message: {
                Text("The session is removed from this iPhone. Your playlists, likes and downloads on this iPhone stay.")
            }
    }
}
