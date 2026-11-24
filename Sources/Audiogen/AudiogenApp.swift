import SwiftUI
import AppKit

#if !arch(arm64)
#error("Audiogen requires Apple Silicon.")
#endif

@main struct AudiogenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = GenerationStore()
    init() {
        // Every view shares one store, so a second window would only mirror the first. AppKit's
        // window restoration brought back every window a Dock reopen had ever added, and the tab
        // bar's + button made more, so launch opens exactly one window and tabs are off.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        NSWindow.allowsAutomaticWindowTabbing = false
        // Left by the Standard/Glass picker, which is gone: glass is the only appearance now.
        UserDefaults.standard.removeObject(forKey: "appearance")
    }
    var body: some Scene {
        WindowGroup("Audiogen") {
            ContentView(store: store).onAppear { delegate.attach(store); delegate.installKeyboardMonitor() }
        }.defaultSize(width: 1140, height: 730)
        // The window's controls live in TopBar, a slim strip beside the traffic lights.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) { SettingsButton { Text("Settings…") }.keyboardShortcut(",") }
            CommandGroup(replacing: .newItem) {
                Button(store.workspace == .generate ? "Import Audio…" : "Import Source Audio…") {
                    if let id = store.workspace.runtime { store.processing.chooseInput(id) } else { store.chooseImport() }
                }.keyboardShortcut("o")
                Button("Choose Reference Audio…") { store.chooseReference() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(store.workspace != .generate || !store.engine.capabilities.referenceAudio)
                Button("Reveal Generation in Finder") { store.reveal(store.selected?.audio) }.disabled(store.selected?.audio == nil)
                Divider()
                Button("Export Audio…") {
                    if let runtime = store.workspace.runtime { if let item = store.processing.record(store.processing.draft(runtime)) { store.processing.export(item) } }
                    else if let item = store.selected { store.export(item) }
                }.keyboardShortcut("e").disabled(exportableCount == 0)
            }
            CommandMenu("Generation") {
                Button("Generate") { store.generate() }.keyboardShortcut(.return, modifiers: .command).disabled(store.workspace != .generate || !store.canGenerate)
                Button("Variation") { if let item = store.selected { store.duplicateSettings(item, variation: true) } }.keyboardShortcut("r").disabled(store.workspace != .generate || store.selected == nil || store.selected?.isImported == true || !store.ready || store.promptFocused)
                Button(store.selected?.isStarred == true ? "Unstar" : "Star") { if let id = store.selectedID { store.toggleStar(id) } }.disabled(store.workspace != .generate || store.selected == nil)
                Button("Repaint Selection") { store.repaintSelection() }.disabled(store.workspace != .generate || !store.engine.capabilities.repaint || store.player.selection == nil || !store.ready || store.prompt.isEmpty)
                Button("Delete Generation") { if let id = store.selectedID { store.delete(id, undoManager: (NSApp.keyWindow ?? NSApp.windows.first { $0.title == "Audiogen" })?.undoManager) } }
                    .disabled(store.workspace != .generate || store.selected == nil || store.selected?.state == .waiting || store.selected?.state == .generating)
                Divider()
                Button("Cancel Generation") { if let item = store.jobs.first { store.cancel(item.id) } }.disabled(store.jobs.isEmpty)
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { store.activePlayer.toggle() }.disabled(store.activePlayer.url == nil)
                Button("Loop Selection") { store.activePlayer.loop.toggle() }.keyboardShortcut("l")
                Button("Jump to Beginning") { store.activePlayer.seek(0) }
            }
            CommandMenu("Engine") {
                ForEach(EngineID.generationCases) { id in Button(id.name) { store.selectEngine(id) }.disabled(!store.canSwitchEngine) }
                Divider()
                Button("Restart Engine") { store.restartEngine() }.disabled(!store.installed || store.engineBusy || !store.jobs.isEmpty)
                SettingsButton { Text("Engine Manager…") }
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Inspector") { store.inspectorVisible.toggle() }.keyboardShortcut("i")
                Button("Show Queue") { store.showQueue.toggle() }
            }
        }
        // A regular window rather than a Settings scene, which SwiftUI keeps at a fixed size. It is
        // small by default and resizes down to 420 × 340: it often sits beside the main window
        // while models download.
        Window("Settings", id: EngineSettings.windowID) { EngineSettings(store: store) }
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .defaultSize(width: 520, height: 560)
            .windowResizability(.contentMinSize)
            .commandsRemoved()
    }
    private var exportableCount: Int {
        if let runtime = store.workspace.runtime { return store.processing.record(store.processing.draft(runtime))?.outputs.count ?? 0 }
        return store.selected?.audio == nil ? 0 : 1
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: GenerationStore?
    private var monitor: Any?
    /// Files opened before the window appeared, such as audio dropped on the Dock icon at launch.
    private var pendingOpen: [URL] = []
    func attach(_ store: GenerationStore) {
        self.store = store
        if !pendingOpen.isEmpty { store.importAudio(pendingOpen); pendingOpen = [] }
    }
    /// Audio dropped on the Dock icon or opened with Audiogen is added to the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let store { store.importAudio(urls) } else { pendingOpen += urls }
    }
    func applicationDidBecomeActive(_ notification: Notification) { store?.refreshInstallState() }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func installKeyboardMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let store = self?.store else { return event }
            guard NSApp.keyWindow?.title == "Audiogen" else { return event }
            let responder = NSApp.keyWindow?.firstResponder
            if responder is NSTextView || responder is NSTextField { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if event.keyCode == 49 { store.activePlayer.toggle(); return nil }
            if event.keyCode == 51 {
                let undo = NSApp.keyWindow?.undoManager
                if store.workspace == .generate, let id = store.selectedID { store.delete(id, undoManager: undo); return nil }
                if let runtime = store.workspace.runtime, let item = store.processing.record(store.processing.draft(runtime)) { store.processing.remove(item, undoManager: undo); return nil }
            }
            return event
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task { await store.shutdownGracefully(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown(); if let monitor { NSEvent.removeMonitor(monitor) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
/// Opens the Settings window, in place of SwiftUI's SettingsLink.
struct SettingsButton<Label: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder let label: () -> Label
    var body: some View { Button(action: { openWindow(id: EngineSettings.windowID) }, label: label) }
}

struct EngineSettings: View {
    static let windowID = "settings"
    @Bindable var store: GenerationStore
    @State private var expanded: Set<EngineID>
    @State private var uninstallTarget: EngineID?

    init(store: GenerationStore) {
        self.store = store
        _expanded = State(initialValue: [])
    }

    enum Pane: String, CaseIterable { case runtimes = "Runtimes", general = "General" }
    @State private var pane = Pane.runtimes

    var body: some View {
        // The tabs live in a compact toolbar beside the traffic lights, in the main window's style.
        // A real toolbar, because macOS gives clicks in the title bar area to the title bar first:
        // as plain content there, quick clicks between tabs went to window dragging instead.
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch pane {
                    case .runtimes: runtimes
                    case .general: general
                    }
                }
                .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 14)
                .buttonStyle(.glass).controlSize(.small)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                BarTabs(label: "Settings", selection: $pane, options: Pane.allCases) { $0.rawValue }.fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .onAppear { store.refreshInstallState() }
        .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity, minHeight: 340, idealHeight: 560, maxHeight: .infinity)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .windowGlass()
        .confirmationDialog("Uninstall \(uninstallTarget?.name ?? "runtime") and its model files? Generated audio will be kept.", isPresented: Binding(get: { uninstallTarget != nil }, set: { if !$0 { uninstallTarget = nil } })) {
            if let target = uninstallTarget {
                Button("Uninstall", role: .destructive) { store.uninstall(target); uninstallTarget = nil }
            }
        }
    }

    /// Every engine in one glass list, a row each, expanding in place to show its models.
    private var runtimes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Download a model here, then choose it in its workspace. Downloads continue while you work.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(EngineID.allCases.enumerated()), id: \.element) { index, id in
                    if index > 0 { GlassRule() }
                    runtimeCard(id)
                }
            }
            .panel(cornerRadius: 12)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsCard("Audio Library") {
                // The folder is the control: click it to choose another.
                Button { store.chooseOutputDirectory() } label: {
                    Label { Text(store.outputDirectory.path).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading) } icon: { Image(systemName: "folder") }
                        .font(.callout).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).pointerStyle(.link)
                .help("Choose another folder")
                Text("Renaming a generation also renames its WAV. Removing it from the library keeps the file on disk.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            settingsCard("Runtime Logs") {
                HStack(spacing: 12) {
                    Text("Engine output, useful when a generation or download fails.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Show in Finder") { store.reveal(store.paths.logs) }
                }
            }
        }
    }

    /// A titled glass card.
    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).panel(cornerRadius: 12)
    }

    /// One engine: name, a one-line description and how many models are installed. Clicking the
    /// row shows its models and runtime underneath.
    private func runtimeCard(_ id: EngineID) -> some View {
        let models = store.models(for: id)
        let installedCount = models.filter { store.modelInstalled(id, model: $0.id) }.count
        let isExpanded = expanded.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(Motion.page) { if isExpanded { expanded.remove(id) } else { expanded.insert(id) } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(id.name).font(.callout.weight(.semibold))
                            Text(description(id)).font(.caption).foregroundStyle(.secondary).lineLimit(isExpanded ? 3 : 1)
                        }
                        Spacer(minLength: 8)
                        Label(store.downloads.active(id) ? "Downloading" : "\(installedCount) of \(models.count)",
                              systemImage: store.downloads.active(id) ? "arrow.down.circle" : installedCount > 0 ? "checkmark.circle" : "circle")
                            .font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(description(id))
                .accessibilityLabel("\(id.name), \(installedCount) of \(models.count) models installed")
                .accessibilityHint(isExpanded ? "Hides models" : "Shows models")
                Menu {
                    Button("Show Files in Finder") { store.reveal(store.engine(for: id).directory) }
                    if id == .ace { Button("Import Local Checkpoint…") { store.importACEModel() } }
                    Divider()
                    Button("Uninstall…", role: .destructive) { uninstallTarget = id }
                        .disabled(!store.runtimeInstalled(id) || store.downloads.active(id) || store.processing.busy(id) || store.engineBusy || store.jobs.contains { $0.resolvedEngineID == id })
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("\(id.name) options")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(models) { model in
                        GlassRule()
                        modelRow(model, engine: id).padding(.vertical, 8)
                    }
                    GlassRule()
                    runtimeRow(id).padding(.vertical, 8)
                    if id == .musicGen {
                        Link("Model license: CC BY-NC 4.0", destination: URL(string: "https://github.com/facebookresearch/audiocraft/blob/main/LICENSE_weights")!)
                            .font(.caption).padding(.bottom, 8)
                    }
                }
                .padding(.leading, 32).padding(.trailing, 12)
                .transition(.opacity)
            }
        }
        .onChange(of: store.downloads.active(id)) { _, active in if active { expanded.insert(id) } }
    }

    private func modelRow(_ model: RuntimeModel, engine id: EngineID) -> some View {
        let task = store.downloads.record(id, model: model.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name).font(.callout.weight(.medium))
                    Text("\(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)) download · \(model.minimumMemoryGB) GB memory required")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if let task, task.active {
                    Button("Pause") { store.downloads.cancel(id, model: model.id) }
                } else if store.modelInstalled(id, model: model.id) {
                    Label("Installed", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(task?.state == .interrupted ? "Resume" : "Download") { store.downloadModel(id, model: model.id) }
                }
            }
            if let task { downloadStatus(task) }
        }
    }

    private func runtimeRow(_ id: EngineID) -> some View {
        let task = store.downloads.record(id, model: "runtime")
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Runtime").font(.callout.weight(.medium))
                    Text(store.runtimeInstalled(id) ? "Installed" : "Installed automatically when you download a model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if let task, task.active {
                    Button("Pause") { store.downloads.cancel(id, model: "runtime") }
                } else if !store.runtimeInstalled(id) {
                    Button(task?.state == .interrupted ? "Resume" : "Install Only") { store.downloadRuntime(id) }
                }
            }
            if let task { downloadStatus(task) }
        }
    }

    @ViewBuilder private func downloadStatus(_ task: RuntimeDownload) -> some View {
        if task.active {
            if let progress = task.progress { ProgressView(value: progress) }
            HStack(spacing: 6) {
                if task.progress == nil && task.state == .running { ProgressView().controlSize(.mini) }
                Text(task.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if task.state == .interrupted {
            Text(task.error ?? "Download paused. Resume to continue.")
                .font(.caption).foregroundStyle(task.error == nil ? Color.secondary : Color.red)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func description(_ id: EngineID) -> String {
        switch id {
        case .ace: "Music generation, reference audio and repainting. Supports LoRAs."
        case .miniMax: "Music generation with Efficient, Balanced and Quality models."
        case .stableAudio: "Music and sound effects, reference audio and repainting. Supports LoRAs."
        case .musicGen: "Instrumental music with mono and stereo models."
        case .yue: "Song generation with optional lyrics and natural endings."
        case .sam: "Extract a described sound and the remaining audio. Used in Extract."
        case .after: "Transfer timbre from a reference recording. Used in Transform."
        }
    }
}
