import SwiftUI

/// Picture presets for the video, like the Android app's video shaders.
///
/// YouTube plays as HLS, and an HLS `AVURLAsset` exposes no video tracks, so
/// `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` cannot be built for it (it traps). The
/// effects are therefore SwiftUI colour effects on the player view, which the compositor applies to
/// the AVPlayerViewController's video layer as well.
enum PicturePreset: String, CaseIterable, Identifiable {
    case off, vivid, warm, cool, mono, sepia, sharpen, night, cinema

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .off: "Off"
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .mono: "Mono"
        case .sepia: "Sepia"
        case .sharpen: "Sharpen"
        case .night: "Night"
        case .cinema: "Cinema"
        }
    }

    var icon: String {
        switch self {
        case .off: "circle.slash"
        case .vivid: "paintpalette"
        case .warm: "sun.max"
        case .cool: "snowflake"
        case .mono: "circle.lefthalf.filled"
        case .sepia: "photo"
        case .sharpen: "camera.aperture"
        case .night: "moon"
        case .cinema: "film"
        }
    }

    /// The preset's own adjustment, before the viewer's sliders.
    var base: PictureAdjustment {
        switch self {
        case .off: PictureAdjustment()
        case .vivid: PictureAdjustment(contrast: 1.08, saturation: 1.45)
        case .warm: PictureAdjustment(saturation: 1.05, tint: Color(red: 1, green: 0.93, blue: 0.82))
        case .cool: PictureAdjustment(tint: Color(red: 0.86, green: 0.94, blue: 1))
        case .mono: PictureAdjustment(contrast: 1.05, saturation: 0)
        case .sepia: PictureAdjustment(brightness: 0.04, saturation: 0, tint: Color(red: 1, green: 0.86, blue: 0.66))
        // Edge sharpening needs a pixel shader; on the system player view a crisper tone curve stands in.
        case .sharpen: PictureAdjustment(contrast: 1.18, saturation: 1.06)
        case .night: PictureAdjustment(brightness: -0.12, contrast: 0.92, saturation: 0.9, tint: Color(red: 1, green: 0.9, blue: 0.78))
        case .cinema: PictureAdjustment(brightness: -0.03, contrast: 1.25, saturation: 0.88, tint: Color(red: 1, green: 0.97, blue: 0.92))
        }
    }
}

struct PictureAdjustment: Equatable {
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var tint: Color = .white
}

/// Applies the remembered picture preset and sliders to a video surface.
struct PictureFilterModifier: ViewModifier {
    @AppStorage("picturePreset") private var presetRaw = PicturePreset.off.rawValue
    @AppStorage("pictureBrightness") private var brightness: Double = 0
    @AppStorage("pictureContrast") private var contrast: Double = 1
    @AppStorage("pictureSaturation") private var saturation: Double = 1

    func body(content: Content) -> some View {
        let base = (PicturePreset(rawValue: presetRaw) ?? .off).base
        content
            .saturation(base.saturation * saturation)
            .contrast(base.contrast * contrast)
            .brightness(base.brightness + brightness)
            .colorMultiply(base.tint)
    }
}

extension View {
    func pictureFilter() -> some View { modifier(PictureFilterModifier()) }
}

/// Whether the Picture sliders sheet is up. Shared so the menu can live inside another menu
/// (iPhone) while the sheet hangs off the watch page.
@MainActor
@Observable
final class PictureAdjustState {
    static let shared = PictureAdjustState()
    var isPresented = false
}

/// The Picture menu on the watch page: presets, then a sheet with brightness, contrast and saturation.
/// As a round button on iPad; as a submenu of the quality menu on iPhone, where the bar has no room.
struct PictureMenu: View {
    var submenu = false
    @AppStorage("picturePreset") private var presetRaw = PicturePreset.off.rawValue
    @AppStorage("pictureBrightness") private var brightness: Double = 0
    @AppStorage("pictureContrast") private var contrast: Double = 1
    @AppStorage("pictureSaturation") private var saturation: Double = 1

    private var isCustomized: Bool {
        presetRaw != PicturePreset.off.rawValue || brightness != 0 || contrast != 1 || saturation != 1
    }

    var body: some View {
        if submenu {
            menu.labelStyle(.titleAndIcon)
        } else {
            menu.buttonStyle(.glass).buttonBorderShape(.circle)
        }
    }

    private var menu: some View {
        Menu {
            Picker("Picture", selection: $presetRaw) {
                ForEach(PicturePreset.allCases) { Label($0.title, systemImage: $0.icon).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Section {
                Button("Adjust…", systemImage: "slider.horizontal.below.square.filled.and.square") { PictureAdjustState.shared.isPresented = true }
                if isCustomized {
                    Button("Reset Picture", systemImage: "arrow.counterclockwise") {
                        presetRaw = PicturePreset.off.rawValue
                        brightness = 0; contrast = 1; saturation = 1
                    }
                }
            }
        } label: {
            if submenu {
                Label("Picture", systemImage: "camera.filters")
            } else {
                Image(systemName: "camera.filters").symbolVariant(isCustomized ? .fill : .none).frame(width: 40, height: 40)
            }
        }
        .accessibilityLabel(Text("Picture"))
    }
}

/// Brightness, contrast and saturation on top of the chosen preset.
struct PictureAdjustSheet: View {
    @AppStorage("picturePreset") private var presetRaw = PicturePreset.off.rawValue
    @AppStorage("pictureBrightness") private var brightness: Double = 0
    @AppStorage("pictureContrast") private var contrast: Double = 1
    @AppStorage("pictureSaturation") private var saturation: Double = 1
    @Environment(\.dismiss) private var dismiss

    private var isCustomized: Bool {
        presetRaw != PicturePreset.off.rawValue || brightness != 0 || contrast != 1 || saturation != 1
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset") {
                    Picker("Preset", selection: $presetRaw) {
                        ForEach(PicturePreset.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section {
                    slider("Brightness", value: $brightness, in: -0.3...0.3, neutral: 0, icon: "sun.max")
                    slider("Contrast", value: $contrast, in: 0.6...1.6, neutral: 1, icon: "circle.righthalf.filled")
                    slider("Saturation", value: $saturation, in: 0...2, neutral: 1, icon: "drop")
                }
                Section {
                    Button("Reset Picture", systemImage: "arrow.counterclockwise", role: .destructive) {
                        presetRaw = PicturePreset.off.rawValue
                        brightness = 0; contrast = 1; saturation = 1
                    }
                    .disabled(!isCustomized)
                }
            }
            .navigationTitle("Picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>, neutral: Double, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(String(format: "%+.0f%%", (value.wrappedValue - neutral) * 100)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .onTapGesture(count: 2) { value.wrappedValue = neutral }
        }
    }
}
