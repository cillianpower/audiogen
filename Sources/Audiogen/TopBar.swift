import SwiftUI
import AppKit

/// Where the main column sits in the window, so the bar can line its sections up with the columns.
struct BarColumns: Equatable {
    var detailMinX: CGFloat = 0
    var detailMaxX: CGFloat?
}

/// One slim strip across the top of the window, as in Stereo, Obsidian and WhatsApp. The controls
/// sit over their own columns: the traffic lights and sidebar toggle over the sidebar, the engine at
/// the start of the main column, and the inspector toggle at the right edge. The workspace tabs are
/// centred in the window, so they stay put whichever workspace or panes are showing. The title bar
/// is hidden, so empty parts of the strip move the window.
struct TopBar: View {
    @Bindable var store: GenerationStore
    @Binding var sidebar: NavigationSplitViewVisibility
    let columns: BarColumns
    static let height: CGFloat = 32
    /// Room for the close, minimize and zoom buttons.
    private static let trafficLights: CGFloat = 76
    /// Where Generate's leading controls end, and how wide the tabs are, so the tabs can keep clear.
    @State private var leadingEnd: CGFloat = 0
    @State private var tabsWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // The layout follows Generate's columns in every workspace; Generate's own controls fade
            // out elsewhere, so nothing else in the bar shifts when you switch.
            let generate = store.workspace == .generate
            let minX = min(max(columns.detailMinX, 0), width)
            let sidebarShown = minX > 1
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if sidebarShown {
                        HStack(spacing: 0) {
                            Spacer(minLength: Self.trafficLights)
                            sidebarToggle.generateOnly(generate)
                        }
                        .padding(.trailing, 8)
                        .frame(width: minX)
                    }
                    HStack(spacing: 4) {
                        if !sidebarShown { sidebarToggle }
                        engine
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).maxX } action: { leadingEnd = $0 }
                    .generateOnly(generate)
                    .padding(.leading, sidebarShown ? 12 : Self.trafficLights)
                    Spacer(minLength: 0)
                    inspectorToggle.generateOnly(generate).padding(.trailing, 8)
                }
                .frame(width: width, height: Self.height)
                BarTabs(label: "Workspace", selection: $store.workspace, options: AudioWorkspace.allCases) { $0.rawValue }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
                    .position(x: tabsCentre(width: width), y: Self.height / 2)
            }
            .frame(width: width, height: Self.height)
            .coordinateSpace(.named(Self.space))
            // The columns report their final positions at once, so the bar follows them with the
            // same spring the panes use.
            .animation(Motion.page, value: columns)
        }
        .frame(height: Self.height)
        .background { WindowDragArea() }
    }

    private static let space = "TopBar"

    /// The window's centre, unless the window is too narrow for that: then just clear of the engine
    /// menu on the left and the inspector toggle on the right.
    private func tabsCentre(width: CGFloat) -> CGFloat {
        let half = tabsWidth / 2, gap: CGFloat = 16
        let lowest = leadingEnd + gap + half
        let highest = width - 8 - 28 - gap - half
        return min(max(width / 2, lowest), max(highest, lowest))
    }

    private var sidebarToggle: some View {
        BarButton("Toggle Sidebar", symbol: "sidebar.left") {
            withAnimation(Motion.page) { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
        }
    }

    private var inspectorToggle: some View {
        BarButton("Inspector", symbol: "sidebar.right", isOn: store.inspectorVisible) { store.inspectorVisible.toggle() }
            .help("Show or hide the inspector (⌘I)")
    }

    /// The engine as plain text with a menu. A starting engine shows a small spinner; one that
    /// needs something (a model, a restart) shows an icon that opens Settings, with the status as
    /// its tooltip, instead of a sentence in the bar.
    private var engine: some View {
        HStack(spacing: 6) {
            Picker("Engine", selection: Binding(get: { store.selectedEngine }, set: store.selectEngine)) {
                ForEach(EngineID.generationCases) { Text($0.name).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).fixedSize()
            .font(.system(size: 12, weight: .medium))
            .disabled(!store.canSwitchEngine).help("Generation engine")
            if store.engineBusy {
                ProgressView().controlSize(.mini)
                    .help(store.engineStatus).accessibilityLabel(store.engineStatus)
            } else if store.engineStatus != "Available" {
                SettingsButton {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 12))
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .buttonStyle(BarPressStyle())
                .foregroundStyle(.secondary)
                .help(store.engineStatus)
                .accessibilityLabel(store.engineStatus)
            }
        }
    }
}

private extension View {
    /// Generate's controls stay in place but fade out and stop taking clicks in other workspaces.
    func generateOnly(_ generate: Bool) -> some View {
        opacity(generate ? 1 : 0).allowsHitTesting(generate).accessibilityHidden(!generate)
            .animation(.easeOut(duration: 0.18), value: generate)
    }
}

/// Small text tabs with a soft pill behind the current one: the workspaces in the main window,
/// the panes in Settings.
struct BarTabs<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button { withAnimation(Motion.hover) { selection = option } } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(height: 22)
                        .background {
                            if isSelected { Capsule().fill(.primary.opacity(0.1)).matchedGeometryEffect(id: "pill", in: pill) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A flat icon button for the bar: no capsule, just a soft highlight under the pointer.
struct BarButton: View {
    let title: String
    let symbol: String
    var isOn = false
    let action: () -> Void
    init(_ title: String, symbol: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.isOn = isOn; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .frame(width: 28, height: 24).contentShape(.rect)
        }
        .buttonStyle(BarPressStyle())
        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct BarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Highlight(configuration: configuration) }
    private struct Highlight: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(isHovering && isEnabled ? 0.08 : 0)))
                .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.4)
                .onHover { hovering in withAnimation(Motion.hover) { isHovering = hovering } }
        }
    }
}

/// Drags the window, and double-clicks the way the user has chosen for title bars.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .onTapGesture(count: 2) {
                guard let window = NSApp.keyWindow else { return }
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.zoom(nil)
                }
            }
    }
}
