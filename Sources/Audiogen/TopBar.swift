import SwiftUI
import AppKit

/// Where the main column sits in the window, so the bar can line its sections up with the columns.
struct BarColumns: Equatable {
    var detailMinX: CGFloat = 0
    var detailMaxX: CGFloat?
}

/// One slim strip across the top of the window, as in Stereo, Obsidian and WhatsApp. Each column
/// owns the part of the strip above it: the sidebar holds the traffic lights and its toggle, the main
/// column holds the engine and the workspace tabs, and the inspector holds its own toggle. The title
/// bar is hidden, so empty parts of the strip move the window.
struct TopBar: View {
    @Bindable var store: GenerationStore
    @Binding var sidebar: NavigationSplitViewVisibility
    let columns: BarColumns
    static let height: CGFloat = 32
    /// Room for the close, minimize and zoom buttons.
    private static let trafficLights: CGFloat = 76

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let generate = store.workspace == .generate
            let minX = generate ? min(max(columns.detailMinX, 0), width) : 0
            let maxX = generate ? min(max(columns.detailMaxX ?? width, minX), width) : width
            let sidebarShown = minX > 1
            HStack(spacing: 0) {
                if sidebarShown {
                    HStack(spacing: 0) {
                        Spacer(minLength: Self.trafficLights)
                        sidebarToggle
                    }
                    .padding(.trailing, 8)
                    .frame(width: minX)
                }
                // The two sides share the leftover width equally, so the tabs stay centred over the
                // main column, and the engine menu sits at its leading edge, never closer than 16 pt.
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        if generate {
                            if !sidebarShown { sidebarToggle }
                            engine
                        }
                    }
                    .padding(.leading, sidebarShown ? 12 : Self.trafficLights)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    WorkspaceTabs(selection: $store.workspace).fixedSize()
                    HStack(spacing: 0) { if generate && maxX >= width - 1 { inspectorToggle } }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.trailing, 8)
                .frame(width: maxX - minX)
                if maxX < width - 1 {
                    HStack(spacing: 0) { Spacer(minLength: 0); inspectorToggle }
                        .padding(.trailing, 8)
                        .frame(width: width - maxX)
                }
            }
            .frame(width: width, height: Self.height)
            // The columns report their final positions at once, so the bar follows them with the
            // same spring the panes use, and the tabs slide instead of jumping.
            .animation(Motion.page, value: columns)
        }
        .frame(height: Self.height)
        .background { WindowDragArea() }
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
                SettingsLink {
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

/// Generate, Extract and Transform as small text tabs, with a soft pill behind the current one.
private struct WorkspaceTabs: View {
    @Binding var selection: AudioWorkspace
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AudioWorkspace.allCases) { workspace in
                let isSelected = selection == workspace
                Button { withAnimation(Motion.hover) { selection = workspace } } label: {
                    Text(workspace.rawValue)
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
        .accessibilityLabel("Workspace")
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
private struct WindowDragArea: View {
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
