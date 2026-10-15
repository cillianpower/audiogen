import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: GenerationStore
    var body: some View {
        Group {
            switch store.workspace {
            case .generate: GenerationWorkspaceView(store: store)
            case .extract: ProcessingWorkspaceView(store: store, engine: .sam)
            case .transform: ProcessingWorkspaceView(store: store, engine: .after)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Workspace", selection: $store.workspace) {
                    ForEach(AudioWorkspace.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .onChange(of: store.activity) { _, activity in DockActivity.update(activity) }
        // The workspace switcher says where you are; the app name adds nothing (HIG: Toolbars).
        .toolbar(removing: .title)
        .windowMaterial()
    }
}

struct GenerationWorkspaceView: View {
    @Bindable var store: GenerationStore
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showAdvanced = false
    @Environment(\.undoManager) private var undoManager
    static let minimumWidthWithInspector: CGFloat = 990
    @State private var composerFullWidth: CGFloat = 0
    @State private var composerWidth: CGFloat = .infinity
    var body: some View {
        HStack(spacing: 0) {
        NavigationSplitView {
            List(selection: $store.selectedID) {
                Section {
                    if store.visibleGenerations.isEmpty && store.isFiltering {
                        Text("No matching generations").foregroundStyle(.secondary)
                    }
                    ForEach(store.visibleGenerations) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text(item.name).lineLimit(1)
                                if item.isStarred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel("Starred") }
                            }
                            HStack {
                                Text(clockText(item.actualDuration ?? item.request.duration))
                                Text(item.source.name)
                                Spacer(minLength: 0)
                                if item.state == .generating { ProgressView().controlSize(.mini) }
                                else if item.state != .ready { Text(item.state.rawValue.capitalized) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(item.id)
                        .onDrag { item.audio.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                        .contextMenu {
                            Button(item.isStarred ? "Unstar" : "Star") { store.toggleStar(item.id) }
                            Button("Export Audio…") { store.export(item) }.disabled(item.audio == nil)
                            Button("Reveal in Finder") { store.reveal(item.audio) }.disabled(item.audio == nil)
                            Divider()
                            if !item.isImported {
                                Button("Duplicate Settings") { store.duplicateSettings(item) }
                                Button("Generate Variation") { store.duplicateSettings(item, variation: true) }.disabled(!store.ready)
                            }
                            if store.engine.capabilities.referenceAudio { Button("Use as Reference") { store.reference = item.audio }.disabled(item.audio == nil) }
                            Button("Send to Extract") { if let url = item.audio { store.send(url, to: .extract) } }.disabled(item.audio == nil)
                            Button("Send to Transform") { if let url = item.audio { store.send(url, to: .transform) } }.disabled(item.audio == nil)
                            if !item.isImported { Button("Copy Prompt") { store.copyPrompt(item) } }
                            Divider()
                            Button("Rename…") { renameText = item.name; renameID = item.id }
                            Button("Delete", role: .destructive) { store.delete(item.id, undoManager: undoManager) }.disabled(item.state == .waiting || item.state == .generating)
                        }
                    }
                } header: { Text("Generations") }
            }
            .audioDropZone("Add to Library") { store.importAudio($0); return true }
            .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search prompts")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    Toggle(isOn: $store.starredOnly) { Label("Starred Only", systemImage: store.starredOnly ? "star.fill" : "star") }
                        .toggleStyle(.button).buttonStyle(.borderless).labelStyle(.iconOnly).foregroundStyle(store.starredOnly ? .yellow : .secondary)
                        .help("Show starred generations only")
                    Picker("Source", selection: $store.sourceFilter) {
                        Text("All Sources").tag(nil as LibrarySource?)
                        Divider()
                        ForEach(EngineID.generationCases) { Text($0.name).tag(LibrarySource.engine($0) as LibrarySource?) }
                        Divider()
                        Text("Imported").tag(LibrarySource.imported as LibrarySource?)
                    }.labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).fixedSize().help("Show audio from one engine, or imported audio")
                    Spacer(minLength: 0)
                }.font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                .barBackdrop().overlay(alignment: .top) { Divider() }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            VStack(spacing: 0) {
                Group { if !store.installed && store.player.url == nil { onboarding } else { player } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .audioDropZone("Add to Library") { store.importAudio($0); return true }
                if store.showQueue, !store.jobs.isEmpty { queue }
                composer
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        if store.inspectorVisible {
            Divider()
            inspector.frame(width: 270).inspectorBackdrop()
        }
        }
        .contentBackdrop()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Picker("Engine", selection: Binding(get: { store.selectedEngine }, set: store.selectEngine)) {
                        ForEach(EngineID.generationCases) { Text($0.name).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize().disabled(!store.canSwitchEngine).help("Generation engine")
                    if store.engineBusy || store.engineStatus != "Available" {
                        if store.engineBusy { ProgressView().controlSize(.small) }
                        Text(store.engineStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: 180, alignment: .leading)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.inspectorVisible.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }.help("Show or hide the inspector (⌘I)")
            }
        }
        // Sidebar, content and inspector minimums; the window widens if the inspector opens in a narrow window.
        .frame(minWidth: store.inspectorVisible ? Self.minimumWidthWithInspector : 740, minHeight: 590)
        .onChange(of: store.inspectorVisible) { _, visible in
            guard visible, let window = NSApp.windows.first(where: { $0.title == "Audiogen" && $0.isVisible }), window.frame.width < Self.minimumWidthWithInspector else { return }
            var frame = window.frame; frame.size.width = Self.minimumWidthWithInspector
            if let screen = window.screen?.visibleFrame, frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
            window.setFrame(frame, display: true, animate: true)
        }
        .alert("Audiogen", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            if store.installed && !store.engineBusy && store.jobs.isEmpty { Button("Restart Engine") { store.restartEngine() } }
            Button("Show Technical Details") { store.reveal(store.paths.logs) }
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            RenameGenerationView(name: $renameText, save: {
                if let id = renameID { store.rename(id, name: renameText) }
                renameID = nil
            }, cancel: { renameID = nil })
        }
    }
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("Welcome to Audiogen").font(.largeTitle.weight(.semibold))
            Text("Local sound design on your Mac. Generate, listen, iterate.").font(.title3).foregroundStyle(.secondary)
            Text("To start, download a model for \(store.engineName) in Settings. Then describe a sound below.")
            SettingsLink { Label("Runtimes & Downloads…", systemImage: "arrow.down.circle") }.buttonStyle(.glassProminent).controlSize(.large)
            Text("You can also drop audio here, or choose File › Import Audio…, to add it to your library.").font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: 440, alignment: .leading).padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var player: some View {
        VStack(spacing: 14) {
            if store.player.url != nil || store.selected != nil || store.reference != nil {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.selected?.name ?? store.reference?.deletingPathExtension().lastPathComponent ?? "Your next sound").font(.title2.weight(.semibold)).lineLimit(1)
                        Text(store.selected.map { $0.isImported ? "Imported audio. Select a region to repaint it, or use it as a reference." : $0.request.prompt } ?? "Reference audio").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            if let selected = store.selected, selected.audio != nil {
                                Button { store.toggleStar(selected.id) } label: { Label(selected.isStarred ? "Unstar" : "Star", systemImage: selected.isStarred ? "star.fill" : "star").labelStyle(.iconOnly) }
                                    .buttonStyle(.glass).foregroundStyle(selected.isStarred ? .yellow : .primary)
                                    .help(selected.isStarred ? "Unstar" : "Star")
                                Button("Export…") { store.export(selected) }.buttonStyle(.glass).help("Export with normalization, trimming or sample rate conversion (⌘E)")
                            }
                            if store.player.url != nil {
                                Label(store.player.selection == nil ? "Drag Audio" : "Drag Selection", systemImage: "arrow.up.doc")
                                    .font(.callout).lineLimit(1).fixedSize().padding(.horizontal, 12).padding(.vertical, 6)
                                    .glassEffect(.regular.interactive(), in: Capsule())
                                    .onDrag { store.dragProvider() }
                                    .help(store.player.selection == nil ? "Drag this WAV into Ableton or Finder. You can also Option-drag the waveform." : "Drag the selected region into Ableton or Finder as its own WAV.")
                            }
                        }
                    }.fixedSize()
                }.padding(.horizontal, 28).padding(.top, 22)
            }
            ZStack {
                NativeWaveform(player: store.player).opacity(store.player.url == nil ? 0 : 1)
                if store.player.loading { ProgressView("Reading audio…") }
                else if store.player.url == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                        Text("Describe a sound below to generate it").font(.title3)
                        Text("Or drop audio here to add it to your library.").foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 180)
            if let message = store.player.error { Text(message).font(.caption).foregroundStyle(.red) }
            if store.player.url != nil {
                HStack(spacing: 18) {
                    Button { store.player.seek(0) } label: { Label("Jump to Beginning", systemImage: "backward.end.fill").labelStyle(.iconOnly) }.buttonStyle(.borderless)
                    Button { store.player.toggle() } label: { Label(store.player.isPlaying ? "Pause" : "Play", systemImage: store.player.isPlaying ? "pause.fill" : "play.fill").labelStyle(.iconOnly).font(.title2).frame(width: 28) }
                        .buttonStyle(.borderless).help("Play / Pause (Space)")
                    Text("\(clockText(store.player.time)) / \(clockText(store.player.duration))").monospacedDigit().foregroundStyle(.secondary)
                    Toggle(isOn: $store.player.loop) { Label("Loop", systemImage: "repeat") }.toggleStyle(.button).buttonStyle(.borderless).labelStyle(.iconOnly).help("Loop selection (⌘L)")
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: $store.player.volume, in: 0...1).frame(width: 90).help("Volume")
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                HStack(spacing: 12) {
                    if let selection = store.player.selection {
                        Text(String(format: "%.1f s → %.1f s", selection.start, selection.end)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        if store.engine.capabilities.repaint { Button("Repaint Selection") { store.repaintSelection() }.disabled(!store.ready || store.prompt.isEmpty).help(store.prompt.isEmpty ? "Describe what to paint into the selection first" : "Regenerate only the selected region") }
                        Button("Clear") { store.player.selection = nil }.buttonStyle(.borderless)
                    } else { Text("Drag to select a region · Option-drag to drag audio out").font(.caption).foregroundStyle(.tertiary) }
                }.frame(height: 26)
            }
        }.padding(.bottom, 12)
    }
    private var queue: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generation Queue").font(.caption).foregroundStyle(.secondary)
            ForEach(store.jobs) { item in
                HStack {
                    if item.state == .generating { ProgressView().controlSize(.small) }
                    Text(item.name).lineLimit(1)
                    Text(item.engine).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if item.state == .generating, let started = store.jobStarted[item.id] {
                        if let fraction = store.jobProgress[item.id] {
                            ProgressView(value: fraction).frame(width: 120)
                            Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(clockText(context.date.timeIntervalSince(started)) + " elapsed").monospacedDigit().foregroundStyle(.secondary)
                        }
                    } else { Text(item.state == .waiting ? "Waiting" : "Generating…").foregroundStyle(.secondary) }
                    Button { store.cancel(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Cancel generation")
                }.font(.callout)
            }
        }.padding(14).panel().padding(.horizontal, 20).padding(.bottom, 10)
    }
    private var composer: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                PromptEditor(text: $store.prompt, history: store.navigatePromptHistory, focusChanged: { store.promptFocused = $0 }, audioDrop: store.dropOnComposer).frame(height: 64)
                if store.prompt.isEmpty { Text("Describe a texture, loop or sound…").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.leading, 13).padding(.top, 10).allowsHitTesting(false) }
            }
            // The full row when it fits; otherwise the options fold into one menu. The full row is
            // measured off-screen, and the row reports no minimum width, so the composer never
            // forces the window wider than it is (for example, with the inspector open).
            Group { if composerWidth >= composerFullWidth { fullControls } else { compactControls } }
                .frame(minWidth: 0, maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { composerWidth = $0 }
                .background { fullControls.fixedSize().hidden().onGeometryChange(for: CGFloat.self) { $0.size.width } action: { composerFullWidth = $0 } }
                .padding(.horizontal, 6)
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 4)
        .audioDropZone(store.engine.capabilities.referenceAudio ? "Use as Reference" : "Add to Library") { store.dropOnComposer($0) }
    }
    private var fullControls: some View {
        HStack(spacing: 10) {
            referenceControl(compact: false)
            Spacer(minLength: 8)
            if store.supportedModes.count > 1 { modePicker.fixedSize() }
            durationPicker.fixedSize()
            takesPicker.fixedSize()
            if store.supportsDualQueue { bothEnginesToggle.fixedSize() }
            generateButton
        }
    }
    private var compactControls: some View {
        HStack(spacing: 8) {
            referenceControl(compact: true)
            Spacer(minLength: 8)
            Menu {
                if store.supportedModes.count > 1 { modePicker }
                durationPicker
                takesPicker
                if store.supportsDualQueue { bothEnginesToggle }
            } label: {
                Text([store.mode == .repaint ? "Repaint" : nil, durationText(store.duration), store.takes == 1 ? "1 take" : "\(store.takes) takes"].compactMap { $0 }.joined(separator: " · "))
            }.fixedSize().help("Mode, duration and takes")
            generateButton
        }
    }
    @ViewBuilder private func referenceControl(compact: Bool) -> some View {
        if store.engine.capabilities.referenceAudio {
            if let reference = store.reference {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    Text(reference.deletingPathExtension().lastPathComponent).lineLimit(1).truncationMode(.middle).frame(maxWidth: compact ? 110 : 200, alignment: .leading)
                    Button { store.clearReference() } label: { Label("Remove Reference", systemImage: "xmark.circle.fill").labelStyle(.iconOnly) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }.font(.callout).padding(.horizontal, 10).padding(.vertical, 4).background(.quaternary.opacity(0.6), in: Capsule())
                .help("Reference audio")
            } else {
                Button { store.chooseReference() } label: { if compact { Label("Reference", systemImage: "plus").labelStyle(.iconOnly) } else { Label("Reference", systemImage: "plus") } }
                    .buttonStyle(.borderless).help("Choose reference audio (⇧⌘O), or drop audio here")
            }
        }
    }
    private var modePicker: some View { Picker("Mode", selection: $store.mode) { ForEach(store.supportedModes) { Text($0.rawValue).tag($0) } }.labelsHidden() }
    private var durationPicker: some View {
        Picker("Duration", selection: $store.duration) { ForEach(store.durationChoices, id: \.self) { Text((store.selectedEngine == .yue ? "Up to " : "") + durationText($0)).tag($0) } }.labelsHidden().disabled(store.mode == .repaint)
            .help(store.selectedEngine.minimumDuration < 10 ? "Duration" : "\(store.engineName) needs at least 10 seconds. Stable Audio and MusicGen render shorter sounds.")
    }
    private var takesPicker: some View {
        Picker("Takes", selection: $store.takes) { ForEach([1, 2, 4], id: \.self) { Text($0 == 1 ? "1 take" : "\($0) takes").tag($0) } }.labelsHidden().help("Queue several takes with different seeds")
    }
    private var bothEnginesToggle: some View {
        Toggle("Both engines", isOn: $store.generateBoth).toggleStyle(.checkbox).disabled(store.mode != .generate).help("Queues ACE-Step and MiniMax, with the selected engine first. Both selected models must be installed.")
    }
    private var generateButton: some View {
        Button { store.generate() } label: { Label("Generate", systemImage: "sparkles") }
            .buttonStyle(.glassProminent).controlSize(.large).disabled(!store.canGenerate).help("Generate (⌘↩)")
    }
    private var inspector: some View {
        Form {
            Section("Generation") {
                LabeledContent("Duration") { Text((store.selectedEngine == .yue ? "Up to " : "") + durationText(store.duration)) }
                TextField("Seed", text: $store.seedText, prompt: Text("Random"))
                HStack { Button("Random") { store.seedText = "" }; Button("Copy Seed") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.seedText, forType: .string) }.disabled(store.seedText.isEmpty) }
            }
            Section("Model") {
                LabeledContent("Engine", value: store.engineName)
                Picker("Model", selection: Binding(get: { store.modelID }, set: store.selectModel)) {
                    ForEach(store.models(for: store.selectedEngine)) { model in
                        Text(model.name + (store.modelInstalled(store.selectedEngine, model: model.id) ? "" : " · Not downloaded")).tag(model.id)
                    }
                }.disabled(!store.canSwitchEngine)
                SettingsLink { Text("Manage Runtimes & Downloads…") }
                if store.selectedEngine == .ace || store.selectedEngine == .stableAudio {
                    Button("Choose LoRA…") { store.chooseLoRA() }
                    if let lora = store.lora {
                        Text(lora.lastPathComponent).font(.caption).lineLimit(2)
                        Slider(value: $store.loraScale, in: 0...1)
                        Text("Strength: \(store.loraScale, specifier: "%.2f")").font(.caption)
                        Button("Remove LoRA") { store.clearLoRA() }
                        Text("Choose an adapter trained for this model.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(store.minimumMemoryGB) GB minimum unified memory").font(.caption).foregroundStyle(.secondary)
            }
            if store.engine.capabilities.lyrics {
                Section("Lyrics") { TextField("Optional lyrics", text: $store.lyrics, axis: .vertical).lineLimit(3...8) }
            }
            Section("Conditioning") {
                Toggle("Instrumental", isOn: $store.instrumental)
                Toggle("No percussion", isOn: $store.noPercussion)
                Toggle("No vocals", isOn: $store.noVocals)
                TextField("Avoid", text: $store.avoid, axis: .vertical).lineLimit(2...4)
                if store.engine.capabilities.referenceAudio {
                    LabeledContent("Reference strength") { Text(store.referenceStrength, format: .number.precision(.fractionLength(1))) }
                    Slider(value: $store.referenceStrength, in: 0...1)
                }
                Text("Constraints are applied to backend conditioning. Results may still contain unwanted sounds.").font(.caption).foregroundStyle(.secondary)
            }
            ClickableDisclosure("Advanced", isExpanded: $showAdvanced) {
                Stepper("Steps: \(store.steps)", value: $store.steps, in: store.selectedEngine == .miniMax ? 2...100 : 1...100)
            }
            if let selected = store.selected, selected.isImported {
                Section("Selected Audio") {
                    LabeledContent("Imported", value: selected.created.formatted(date: .abbreviated, time: .shortened))
                    if let file = selected.audio { Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if store.engine.capabilities.referenceAudio { Button("Use as Reference") { store.reference = selected.audio } }
                }
            } else if let selected = store.selected {
                Section("Selected Audio") {
                    Text(selected.created, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                    Text("Seed \(selected.request.seed)").textSelection(.enabled)
                    if let message = selected.error { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Button("Restore Settings") { store.duplicateSettings(selected) }
                }
            }
        }.formStyle(.grouped).glassFormBackground()
    }
}

private struct RenameGenerationView: View {
    @Binding var name: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Generation").font(.headline)
            TextField("Name", text: $name).focused($nameFocused).onSubmit { if valid { save() } }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 360).onAppear { nameFocused = true }
    }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
func durationText(_ seconds: Double) -> String {
    seconds == seconds.rounded() ? "\(Int(seconds)) sec" : String(format: "%.1f sec", seconds)
}
