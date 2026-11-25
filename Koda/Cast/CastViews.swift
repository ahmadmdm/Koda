import GoogleCast
import SwiftUI
import UIKit

/// Google's Cast button: it shows the connection state, and opens the device picker.
struct CastButton: UIViewRepresentable {
    var tint: UIColor = .label

    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = tint
        button.delegate = CastManager.shared
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .vertical)
        return button
    }

    func updateUIView(_ button: GCKUICastButton, context: Context) {
        button.tintColor = tint
    }
}

/// The Cast button in the same round glass as the AirPlay button beside it.
struct CastGlassButton: View {
    var body: some View {
        CastButton()
            .frame(width: GlassControl.glassIcon, height: GlassControl.glassIcon)
            .padding(6)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Cast")
    }
}

/// "Casting to Living Room TV", while a session is up.
struct CastingLabel: View {
    @Environment(CastManager.self) private var cast

    var body: some View {
        if cast.isConnected, let name = cast.deviceName {
            Label("Casting to \(name)", systemImage: "tv")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if cast.isConnecting {
            Label("Connecting…", systemImage: "tv")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity)
        }
    }
}

/// Cast choices for a menu, where a `GCKUICastButton` can't go: the watch page's menu on iPhone.
struct CastMenuItems: View {
    @Environment(CastManager.self) private var cast

    var body: some View {
        if cast.isConnected {
            Button("Stop Casting", systemImage: "tv.slash") { cast.endSession() }
        } else {
            Button("Cast to a Device", systemImage: "tv") {
                // After the menu has gone, so the picker isn't presented from under it.
                Task { try? await Task.sleep(for: .milliseconds(350)); cast.presentDialog() }
            }
        }
    }
}

/// Covers the video while it plays on the receiver: where it plays, and its controls.
struct CastingVideoOverlay: View {
    @Environment(VideoPlayerModel.self) private var model
    @Environment(CastManager.self) private var cast
    @State private var dragging: Double?

    var body: some View {
        let duration = max(model.duration, 1)
        let value = dragging ?? model.castPosition
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Label("Casting to \(cast.deviceName ?? "")", systemImage: "tv")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 28) {
                    Button { model.seek(to: max(0, model.castPosition - 10)) } label: { Image(systemName: "gobackward.10").font(.title2) }
                        .accessibilityLabel("Back 10 seconds")
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                    Button { model.seek(to: min(duration, model.castPosition + 10)) } label: { Image(systemName: "goforward.10").font(.title2) }
                        .accessibilityLabel("Forward 10 seconds")
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    Text(value.formattedDuration)
                    Slider(value: Binding(get: { min(value, duration) }, set: { dragging = $0 }), in: 0...duration) { editing in
                        if !editing, let d = dragging { model.seek(to: d); dragging = nil }
                    }
                    .tint(.white)
                    Text(duration.formattedDuration)
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 20)
                .environment(\.layoutDirection, .leftToRight)
                Button("Stop Casting") { cast.endSession() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.glass)
            }
            .foregroundStyle(.white)
            .padding()
        }
    }
}

/// The app's toast, also over the full-screen player and watch page (which cover the root's).
struct ToastOverlay: ViewModifier {
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = app.toast {
                    Text(toast).font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
            .animation(.spring(duration: 0.35), value: app.toast)
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}
