import SwiftUI
import AppKit

// Audiogen has one look: a translucent window that blurs the desktop, with Liquid Glass panels and
// controls on top. Its colour comes from the wallpaper behind it and the accent colour, never from
// painted decoration. With Reduce Transparency on, the system makes these materials opaque.

/// Shared motion, so everything moves with the same feel (as in Tuner).
enum Motion {
    /// Pointer feedback: quick, with a little bounce.
    static let hover = Animation.spring(response: 0.28, dampingFraction: 0.72)
    /// Moving between workspaces.
    static let page = Animation.spring(response: 0.42, dampingFraction: 0.88)
    /// Surfaces appearing or changing shape, such as the generation queue.
    static let morph = Animation.spring(response: 0.56, dampingFraction: 0.84)
}

/// A content panel in Liquid Glass.
private struct Panel: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A soft blur that fades out away from an edge, so a bar sits on the glass without a hard line.
private struct EdgeFade: ViewModifier {
    let edge: VerticalEdge
    func body(content: Content) -> some View {
        content.background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.85), location: 0),
                        .init(color: .black.opacity(0.5), location: 0.6),
                        .init(color: .clear, location: 1),
                    ], startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
                }
                .padding(edge == .top ? .bottom : .top, -14)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func panel(cornerRadius: CGFloat = 14) -> some View { modifier(Panel(cornerRadius: cornerRadius)) }
    /// The window is translucent and blurs the desktop behind it.
    func windowGlass() -> some View {
        containerBackground(for: .window) { WindowBlur() }
    }
    /// Grouped forms and lists drop their opaque backing so the window shows through.
    func clearScrollBackground() -> some View { scrollContentBackground(.hidden) }
    /// A bar pinned to the top or bottom edge of a column.
    func edgeFade(_ edge: VerticalEdge) -> some View { modifier(EdgeFade(edge: edge)) }
}

/// A behind-window blur that stays live when the window is in the background. SwiftUI's window
/// materials follow the window's active state, so an inactive window turned flat grey.
private struct WindowBlur: NSViewRepresentable {
    /// Clears the window's own backing once attached, so the blur shows the desktop, not grey.
    final class BlurView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BlurView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A hairline between columns, faint enough to read as a fold in the glass rather than a rule.
struct GlassSeam: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.08)).frame(width: 1).accessibilityHidden(true) }
}

/// The horizontal counterpart of GlassSeam, between rows inside a card.
struct GlassRule: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1).accessibilityHidden(true) }
}

/// A titled group for the inspector: a small header and its controls directly on the glass.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The little equalizer on the row that's playing. It rests when paused.
struct PlayingBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isPlaying || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().frame(width: 2, height: height(i, t))
                }
            }
            .frame(height: 11, alignment: .bottom)
        }
        .foregroundStyle(.tint)
        .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }

    private func height(_ bar: Int, _ time: TimeInterval) -> CGFloat {
        guard isPlaying, !reduceMotion else { return 3 + CGFloat(bar % 2) * 2 }
        return 3 + 8 * abs(sin(time * (2.1 + Double(bar) * 0.7) + Double(bar) * 1.3))
    }
}
