import SwiftUI

/// Settings › Last.fm: the user's own API account, sign-in with `auth.getMobileSession`, and scrobbling.
struct LastFmSection: View {
    @State private var scrobbler = Scrobbler.shared
    @State private var apiKey = ""
    @State private var secret = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmForget = false

    var body: some View {
        Section {
            if let user = scrobbler.username {
                LabeledContent("Signed in as", value: user)
                Toggle("Scrobble songs", isOn: $scrobbler.enabled)
                if scrobbler.pendingCount > 0 {
                    LabeledContent("Waiting to send", value: scrobbler.pendingCount.formatted())
                    Button("Send now", systemImage: "arrow.up.circle") { scrobbler.flush() }
                }
                Button("Sign out of Last.fm", role: .destructive) { scrobbler.signOut() }
            } else {
                TextField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(apiKey.isEmpty ? .body : .body.monospaced()) // a monospaced placeholder spreads Arabic letters apart
                SecureField(scrobbler.hasSecret && secret.isEmpty ? "Shared secret (saved)" : "Shared secret", text: $secret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Last.fm username", text: $username)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button {
                    Task {
                        // An empty secret field keeps the one already in the Keychain.
                        await scrobbler.signIn(apiKey: apiKey, secret: secret.isEmpty ? storedSecret : secret,
                                               username: username, password: password)
                        password = ""
                        if scrobbler.isSignedIn { secret = "" }
                    }
                } label: {
                    HStack {
                        Text("Sign in to Last.fm")
                        if scrobbler.isSigningIn { Spacer(); ProgressView() }
                    }
                }
                .disabled(scrobbler.isSigningIn || apiKey.isEmpty || (secret.isEmpty && !scrobbler.hasSecret) || username.isEmpty || password.isEmpty)
                if !scrobbler.apiKey.isEmpty {
                    Button("Remove API key and secret", role: .destructive) { confirmForget = true }
                }
            }
            if let error = scrobbler.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Last.fm")
        } footer: {
            Text("Koda scrobbles with your own Last.fm API account. Create one at last.fm/api/account/create (any application name; leave the callback URL empty), then paste its API key and shared secret here. Your password is sent only to Last.fm over HTTPS to start a session and is never stored; the session, key and secret stay in the Keychain on this iPhone. Songs are scrobbled after half their length or 4 minutes; songs of 30 seconds or less are skipped.")
        }
        .onAppear { if apiKey.isEmpty { apiKey = scrobbler.apiKey } }
        .confirmationDialog("Remove the Last.fm API key?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { scrobbler.forgetKeys(); apiKey = ""; secret = "" }
        }
    }

    private var storedSecret: String { scrobbler.storedSecret(forKey: apiKey) }
}
