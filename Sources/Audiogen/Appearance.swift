import SwiftUI

/// Standard follows the Human Interface Guidelines: Liquid Glass for controls and navigation,
/// standard materials for content. Glass extends Liquid Glass to panels and makes the window
/// translucent. Both fall back to opaque surfaces when Reduce Transparency is on.
enum AppAppearance: String, CaseIterable, Identifiable {
    case standard, glass
    var id: Self { self }
    var title: String { self == .standard ? "Standard" : "Glass" }
    static let key = "appearance"
}

/// A content panel: a standard material in Standard, Liquid Glass in Glass.
private struct Panel: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.standard
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if appearance == .glass {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.background.secondary, in: shape)
                .overlay(shape.strokeBorder(.separator.opacity(0.6)))
        }
    }
}

/// The content area's background: the system background in Standard; in Glass, a soft tint
/// over the translucent window that extends beneath the sidebar.
private struct ContentBackdrop: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.standard
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        if appearance == .glass {
            content.background { AmbientTint(dark: colorScheme == .dark).backgroundExtensionEffect().ignoresSafeArea() }
        } else {
            content.background(.background)
        }
    }
}

/// In Glass, the window itself is translucent and blurs the desktop behind it.
private struct WindowMaterial: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.standard
    func body(content: Content) -> some View {
        if appearance == .glass { content.containerBackground(.ultraThinMaterial, for: .window) } else { content }
    }
}

/// Grouped forms drop their opaque backing in Glass so the window shows through.
private struct GlassFormBackground: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.standard
    func body(content: Content) -> some View { content.scrollContentBackground(appearance == .glass ? .hidden : .automatic) }
}

/// A slow, low-contrast colour field that gives the glass something to refract.
struct AmbientTint: View {
    let dark: Bool
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.55, 0.45], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1]
        ], colors: [
            .indigo, .purple, .blue,
            .teal, .indigo, .pink,
            .blue, .cyan, .purple
        ]).opacity(dark ? 0.22 : 0.14)
    }
}

extension View {
    func panel(cornerRadius: CGFloat = 14) -> some View { modifier(Panel(cornerRadius: cornerRadius)) }
    func contentBackdrop() -> some View { modifier(ContentBackdrop()) }
    func windowMaterial() -> some View { modifier(WindowMaterial()) }
    func glassFormBackground() -> some View { modifier(GlassFormBackground()) }
    func inspectorBackdrop() -> some View { modifier(InspectorBackdrop()) }
    func barBackdrop() -> some View { modifier(BarBackdrop()) }
}

/// Settings → General and View menu control.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.standard
    var title = "Appearance"
    var body: some View {
        Picker(title, selection: $appearance) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0) } }
    }
}
struct GlassAppearanceToggle: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.standard
    var body: some View {
        Toggle("Glass Appearance", isOn: Binding(get: { appearance == .glass }, set: { appearance = $0 ? .glass : .standard }))
    }
}

/// The inspector column: the window background in Standard; clear in Glass, over the window's material.
private struct InspectorBackdrop: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.standard
    func body(content: Content) -> some View {
        if appearance == .glass { content } else { content.background(.background) }
    }
}

/// Small bars inside a column, such as the sidebar's filter bar.
private struct BarBackdrop: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.standard
    func body(content: Content) -> some View {
        if appearance == .glass { content.background(.ultraThinMaterial) } else { content.background(.bar) }
    }
}
