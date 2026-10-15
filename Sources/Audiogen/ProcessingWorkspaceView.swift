import SwiftUI
import UniformTypeIdentifiers

struct ProcessingWorkspaceView: View {
    @Bindable var store: GenerationStore
    let engine: EngineID
    @State private var showAdvanced = false
    @State private var showHistory = true
    @Environment(\.undoManager) private var undoManager
    private var processing: ProcessingStore { store.processing }
    private var draft: ProcessingDraft { processing.draft(engine) }
    private var selected: ProcessingRecord? { processing.record(draft) }
    var body: some View {
        @Bindable var draft = draft
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(engine == .sam ? "Extract a sound" : "Transform timbre").font(.title.weight(.semibold))
                        Text(engine == .sam ? "Describe a sound to isolate from a recording." : "Use a reference recording to change the sound character of your source.")
                            .foregroundStyle(.secondary)
                        Text(engine.name).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    SettingsLink { Label("Models & Downloads", systemImage: "arrow.down.circle") }.buttonStyle(.glass)
                }
                if engine == .sam {
                    inputCard(reference: false)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sound to extract").font(.headline)
                        TextField("For example, metallic percussion or a person speaking", text: $draft.sound).textFieldStyle(.roundedBorder)
                        if draft.source != nil {
                            if draft.duration <= 30 {
                                HStack {
                                    Button("Sound is here") { processing.addAnchor(present: true) }.disabled(draft.sourcePlayer.selection == nil || draft.anchors.count >= 3)
                                    Button("Sound is absent here") { processing.addAnchor(present: false) }.disabled(draft.sourcePlayer.selection == nil || draft.anchors.count >= 3)
                                    Text("Select a waveform region to add an example.").font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(draft.anchors) { anchor in
                                    HStack {
                                        Label(anchor.present ? "Sound is here" : "Sound is absent here", systemImage: anchor.present ? "plus.circle" : "minus.circle")
                                        Text(String(format: "%.2f–%.2f sec", anchor.region.start, anchor.region.end)).monospacedDigit()
                                        Spacer()
                                        Button { draft.anchors.removeAll { $0.id == anchor.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Remove example")
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Examples identify the sound; they do not crop the result. Up to three examples.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Long recordings use chunked separation. Sound examples are available for sources up to 30 seconds.").font(.caption).foregroundStyle(.secondary)
                                if !draft.anchors.isEmpty { Button("Remove examples for long-file processing") { draft.anchors = [] } }
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        inputCard(reference: false)
                        inputCard(reference: true)
                    }
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Model", selection: $draft.model) {
                            ForEach(store.models(for: engine)) { model in
                                Text(model.name + (store.modelInstalled(engine, model: model.id) ? "" : " · Not downloaded")).tag(model.id)
                            }
                        }.frame(maxWidth: 300)
                        if draft.sourceChannels > 1 {
                            Toggle("Keep stereo", isOn: $draft.stereo)
                                .help("Processes the left and right channels separately. Takes about twice as long.")
                        }
                        Text((draft.sourceChannels > 1 && draft.stereo ? "Each channel is processed separately, so this takes about twice as long." : "Exports mono audio at the model's native sample rate.") + (engine == .after ? " Choose a model matching the reference's sound family." : ""))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !store.modelInstalled(engine, model: draft.model) {
                            SettingsLink { Text("Download this model in Settings…") }.font(.callout)
                        }
                    }
                    Spacer()
                    if draft.importing { ProgressView("Importing audio…").controlSize(.small) }
                    Button(engine == .sam ? "Extract" : "Transform") { processing.enqueue(engine) }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .disabled(!store.modelInstalled(engine, model: draft.model) || !processing.canRun(engine))
                }
                ClickableDisclosure("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Seed")
                            TextField("Random", text: $draft.seedText).textFieldStyle(.roundedBorder).frame(width: 170)
                            Spacer()
                            Stepper("Steps: \(draft.steps)", value: $draft.steps, in: 2...32).fixedSize()
                        }
                        if engine == .after {
                            HStack { Text("Follow source structure"); Slider(value: $draft.guidance, in: 0...3); Text(String(format: "%.2f", draft.guidance)).monospacedDigit().frame(width: 44) }
                            Text("1 is the model default. Higher values increase source-structure guidance.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 12)
                }
                if let item = selected {
                    if item.state == .waiting || item.state == .processing {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(processing.status[item.id] ?? (item.state == .waiting ? "Queued" : "Processing…"))
                                Spacer()
                                Button("Cancel") { processing.cancel(item.id) }
                            }
                            if let fraction = processing.progress[item.id] { ProgressView(value: fraction) }
                        }.padding(16).panel()
                    } else if item.state == .ready { resultPanel(item) }
                    else if let error = item.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    else if item.state == .cancelled { Text("Processing cancelled.").foregroundStyle(.secondary) }
                }
                ClickableDisclosure("History", isExpanded: $showHistory) {
                    let items = processing.records.filter { $0.request.engine == engine }
                    if items.isEmpty { Text("Processed audio will appear here.").foregroundStyle(.secondary).padding(.vertical, 12) }
                    else {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                HStack {
                                    Button { processing.select(item) } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(item.name).lineLimit(1)
                                                Text(item.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if item.state == .waiting || item.state == .processing {
                                        Button("Cancel") { processing.cancel(item.id) }
                                    } else {
                                        Menu {
                                            Button("Show in Finder") { processing.reveal(item.outputs.first?.file) }.disabled(item.outputs.isEmpty)
                                            Button("Export Audio…") { processing.export(item) }.disabled(item.outputs.isEmpty)
                                            Button("Remove from History", role: .destructive) { processing.remove(item, undoManager: undoManager) }
                                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                                    }
                                }.padding(.vertical, 12)
                                Divider()
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .contentBackdrop()
        .frame(minWidth: 860, minHeight: 590)
        .alert("Audio Processing", isPresented: Binding(get: { processing.error != nil }, set: { if !$0 { processing.error = nil } })) {
            Button("Show Logs") { processing.reveal(store.paths.logs) }
            Button("OK", role: .cancel) { processing.error = nil }
        } message: { Text(processing.error ?? "") }
    }
    private func inputCard(reference: Bool) -> some View {
        let player = reference ? draft.referencePlayer : draft.sourcePlayer
        let url = reference ? draft.reference : draft.source
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(reference ? "Timbre reference" : "Source audio").font(.headline)
                Spacer()
                Button(url == nil ? "Choose Audio…" : "Replace…") { processing.chooseInput(engine, reference: reference) }
            }
            if let url {
                Text(url.deletingPathExtension().lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                NativeWaveform(player: player).frame(height: engine == .sam ? 150 : 120)
                HStack {
                    Button { let playing = player.isPlaying; draft.pausePlayers(); if !playing { player.toggle() } } label: { Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") }
                        .disabled(player.loading)
                    Text("\(clockText(player.time)) / \(clockText(player.duration))").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let message = player.error { Text(message).font(.caption).foregroundStyle(.red) }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.badge.plus").font(.title2).foregroundStyle(.secondary)
                    Text(reference ? "Drop a reference up to 30 seconds" : "Drop audio here").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: engine == .sam ? 180 : 160)
            }
        }.padding(16).panel()
            .dropDestination(for: URL.self) { urls, _ in guard let url = urls.first else { return false }; processing.importInput(url, engine: engine, reference: reference); return true }
    }
    private func resultPanel(_ item: ProcessingRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Result").font(.headline)
                Spacer()
                Menu("Send To") {
                    ForEach(item.outputs) { output in
                        Section(item.outputs.count > 1 ? output.role.rawValue : "") {
                            ForEach(SendDestination.allCases) { destination in
                                Button(destination.title) { store.send(output.file, to: destination) }
                                    .disabled(destination == .timbre && (output.duration ?? 0) > 30)
                            }
                        }
                    }
                }.fixedSize().help("Use this result in Generate, Extract or Transform")
                Button(item.outputs.count == 2 ? "Export Both…" : "Export Audio…") { processing.export(item) }
            }
            Picker("Audition", selection: Binding(get: { draft.auditionRole }, set: { processing.audition(engine, role: $0) })) {
                Text("Original").tag(nil as AudioOutputRole?)
                ForEach(item.outputs) { Text($0.role.rawValue).tag(Optional($0.role)) }
            }.pickerStyle(.segmented)
            NativeWaveform(player: draft.auditionPlayer).frame(height: 140)
            HStack {
                Button { let playing = draft.auditionPlayer.isPlaying; draft.pausePlayers(); if !playing { draft.auditionPlayer.toggle() } } label: { Label(draft.auditionPlayer.isPlaying ? "Pause" : "Play", systemImage: draft.auditionPlayer.isPlaying ? "pause.fill" : "play.fill") }
                    .disabled(draft.auditionPlayer.loading)
                Text("\(clockText(draft.auditionPlayer.time)) / \(clockText(draft.auditionPlayer.duration))").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                ForEach(item.outputs) { output in
                    Label(output.role.rawValue, systemImage: "arrow.up.doc").font(.callout)
                        .onDrag { NSItemProvider(contentsOf: output.file) ?? NSItemProvider() }.help("Drag WAV into Ableton or Finder")
                }
            }
            if let error = draft.auditionPlayer.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(16).panel()
    }
}
