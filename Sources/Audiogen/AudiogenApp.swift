import SwiftUI
import AppKit

#if !arch(arm64)
#error("Audiogen requires Apple Silicon.")
#endif

@main struct AudiogenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = GenerationStore()
    var body: some Scene {
        WindowGroup("Audiogen") {
            ContentView(store: store).onAppear { delegate.attach(store); delegate.installKeyboardMonitor() }
        }.defaultSize(width: 1140, height: 730)
        .commands {
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
                SettingsLink { Text("Engine Manager…") }
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Inspector") { store.inspectorVisible.toggle() }.keyboardShortcut("i")
                GlassAppearanceToggle()
                Button("Show Queue") { store.showQueue.toggle() }
            }
        }
        Settings { EngineSettings(store: store) }
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
struct EngineSettings: View {
    @Bindable var store: GenerationStore
    @State private var expanded: Set<EngineID>
    @State private var uninstallTarget: EngineID?

    init(store: GenerationStore) {
        self.store = store
        _expanded = State(initialValue: [])
    }

    var body: some View {
        TabView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Runtimes & Models").font(.title2.weight(.semibold))
                        Text("Download models here, then choose one in its workspace. Downloads can continue while you process audio.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.bottom, 4)
                    ForEach(EngineID.allCases) { id in runtimeCard(id) }
                }.padding(24)
            }.contentBackdrop()
                .tabItem { Label("Runtimes", systemImage: "cpu") }

            Form {
                Section("Appearance") {
                    AppearancePicker(title: "Style").pickerStyle(.segmented)
                    Text("Standard follows macOS: Liquid Glass for controls, solid panels for content. Glass makes the window translucent and turns panels into Liquid Glass. Both become solid when Reduce Transparency is on in Accessibility settings.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section("Audio Library") {
                    LabeledContent("Save audio to") {
                        Text(store.outputDirectory.path).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                    Button("Change Folder…") { store.chooseOutputDirectory() }
                    Text("Renaming a generation also renames its WAV. Removing it from the library keeps the file on disk.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    LabeledContent("Runtime logs") {
                        Button("Show in Finder") { store.reveal(store.paths.logs) }
                    }
                }
            }.formStyle(.grouped).glassFormBackground().contentBackdrop().tabItem { Label("General", systemImage: "gearshape") }
        }.frame(width: 700, height: 650)
        .windowMaterial()
        .confirmationDialog("Uninstall \(uninstallTarget?.name ?? "runtime") and its model files? Generated audio will be kept.", isPresented: Binding(get: { uninstallTarget != nil }, set: { if !$0 { uninstallTarget = nil } })) {
            if let target = uninstallTarget {
                Button("Uninstall", role: .destructive) { store.uninstall(target); uninstallTarget = nil }
            }
        }
    }

    private func runtimeCard(_ id: EngineID) -> some View {
        let models = store.models(for: id)
        let installedCount = models.filter { store.modelInstalled(id, model: $0.id) }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(id.name).font(.headline)
                    Text(description(id)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Menu {
                    Button("Show Files in Finder") { store.reveal(store.engine(for: id).directory) }
                    if id == .ace { Button("Import Local Checkpoint…") { store.importACEModel() } }
                    Divider()
                    Button("Uninstall…", role: .destructive) { uninstallTarget = id }
                        .disabled(!store.runtimeInstalled(id) || store.downloads.active(id) || store.processing.busy(id) || store.engineBusy || store.jobs.contains { $0.resolvedEngineID == id })
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("\(id.name) options")
            }
            ClickableDisclosure(isExpanded: Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(models) { model in
                        Divider().padding(.vertical, 12)
                        modelRow(model, engine: id)
                    }
                    Divider().padding(.vertical, 12)
                    runtimeRow(id)
                    if id == .musicGen {
                        Link("Model license: CC BY-NC 4.0", destination: URL(string: "https://github.com/facebookresearch/audiocraft/blob/main/LICENSE_weights")!)
                            .font(.caption).padding(.top, 12)
                    }
                }
            } label: {
                HStack {
                    Text("Models").font(.callout.weight(.medium))
                    Spacer()
                    Label(store.downloads.active(id) ? "Download in progress" : installedCount > 0 ? "\(installedCount) of \(models.count) installed" : "None installed",
                          systemImage: store.downloads.active(id) ? "arrow.down.circle" : installedCount > 0 ? "checkmark.circle" : "circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .panel()
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
