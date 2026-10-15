import Foundation
import AppKit
import Observation

@MainActor @Observable final class GenerationStore {
    let paths: AppPaths
    let preferences: UserDefaults
    let manifest: EngineManifest
    let ace: ACEEngine
    let miniMax: MiniMaxEngine
    let catalog: RuntimeCatalog
    let pythonEngines: [EngineID: PythonEngine]
    let downloads = RuntimeDownloads()
    let scheduler = AudioWorkScheduler()
    let processing: ProcessingStore
    var workspace: AudioWorkspace = .generate {
        didSet { if player.isPlaying { player.toggle() }; processing.extract.pausePlayers(); processing.transform.pausePlayers() }
    }
    var activePlayer: AudioPlayer {
        switch workspace {
        case .generate: player
        case .extract: processing.extract.auditionPlayer.url == nil ? processing.extract.sourcePlayer : processing.extract.auditionPlayer
        case .transform: processing.transform.auditionPlayer.url == nil ? processing.transform.sourcePlayer : processing.transform.auditionPlayer
        }
    }
    var selectedModels: [EngineID: String] = [:]
    var selectedEngine: EngineID = .ace
    var engine: any GenerationEngine { engine(for: selectedEngine) }
    var engineName: String { selectedEngine.name }
    var supportedModes: [GenerationMode] { engine.capabilities.repaint ? [.generate, .repaint] : [.generate] }
    var modelID: String { selectedModels[selectedEngine] ?? models(for: selectedEngine)[0].id }
    var currentModel: RuntimeModel { models(for: selectedEngine).first { $0.id == modelID } ?? models(for: selectedEngine)[0] }
    var presetName: String { currentModel.name }
    var minimumMemoryGB: Int { currentModel.minimumMemoryGB }
    var modelDownloadBytes: Int64 { currentModel.bytes }
    var engineDirectory: URL { engine.directory }
    var canSwitchEngine: Bool { !engineBusy && !stopping }
    var supportsDualQueue: Bool { selectedEngine == .ace || selectedEngine == .miniMax }
    func models(for id: EngineID) -> [RuntimeModel] {
        switch id {
        case .ace:
            let turbo = RuntimeModel(id: ACEModel.turbo.rawValue, name: "Turbo", minimumMemoryGB: 16, steps: 8, files: manifest.models)
            return [turbo] + catalog.aceModels.map { RuntimeModel(id: $0.id, name: $0.name, minimumMemoryGB: $0.minimumMemoryGB, steps: $0.steps, files: ace.installer.commonModels + $0.files) }
        case .miniMax: return miniMax.manifest.presets.map { RuntimeModel(id: $0.id, name: $0.name, minimumMemoryGB: $0.minimumMemoryGB, steps: $0.steps, files: $0.models) }
        default: return pythonEngines[id]!.spec.models
        }
    }
    func modelInstalled(_ id: EngineID, model: String) -> Bool {
        _ = downloads.record(id, model: model)?.state
        switch id {
        case .ace: return ace.installer.modelInstalled(model)
        case .miniMax: return miniMax.manifest.presets.first { $0.id == model }.map { miniMax.isInstalled($0) } ?? false
        default: return pythonEngines[id]!.spec.models.first { $0.id == model }.map { pythonEngines[id]!.isInstalled($0) } ?? false
        }
    }
    func runtimeInstalled(_ id: EngineID) -> Bool {
        _ = downloads.record(id, model: "runtime")?.state
        return switch id { case .ace: ace.installer.runtimeInstalled; case .miniMax: FileManager.default.isExecutableFile(atPath: miniMax.binary.path); default: pythonEngines[id]!.runtimeInstalled }
    }
    func downloadRuntime(_ id: EngineID) {
        downloads.enqueue(engine: id, model: "runtime") { [self] progress in
            switch id {
            case .ace: try await ace.installer.installRuntime(progress: progress)
            case .miniMax: try await miniMax.installRuntime(progress: progress)
            default: try await pythonEngines[id]!.installRuntime(progress: progress)
            }
        }
    }
    func downloadModel(_ id: EngineID, model: String) {
        guard let chosen = models(for: id).first(where: { $0.id == model }) else { return }
        downloads.enqueue(engine: id, model: model) { [self] progress in
            switch id {
            case .ace:
                try await ace.installer.installRuntime(progress: progress)
                try await PythonEngine.installFiles(chosen.files, root: paths.models, downloads: paths.runtime.appendingPathComponent("downloads"), progress: progress)
                refreshACEModels()
            case .miniMax: try await miniMax.install(presetID: model, progress: progress)
            default: try await pythonEngines[id]!.install(modelID: model, progress: progress)
            }
            if selectedEngine == id && modelID == model { ready = true; engineStatus = "Available" }
        }
    }
    func configure(_ worker: any GenerationEngine, id: EngineID, model: String) async {
        switch id {
        case .ace:
            if ace.modelID != model { await ace.stop() }; ace.modelID = model
        case .miniMax: miniMax.presetID = model
        default: pythonEngines[id]!.modelID = model
        }
    }
    var generateBoth = false
    /// How many takes, each with its own seed, one Generate press queues.
    var takes = 1 { didSet { preferences.set(takes, forKey: "takes") } }
    var durationChoices: [Double] {
        var choices = selectedEngine.durationChoices
        if !choices.contains(duration) { choices.append(duration); choices.sort() }
        return choices
    }
    var searchText = ""
    var starredOnly = false
    var sourceFilter: LibrarySource?
    var isFiltering: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty || starredOnly || sourceFilter != nil }
    var visibleGenerations: [Generation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return generations.filter { item in
            (!starredOnly || item.isStarred) && (sourceFilter == nil || item.source == sourceFilter) &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || item.request.prompt.localizedCaseInsensitiveContains(query))
        }
    }
    let exportSettings: ExportSettings
    var jobProgress: [UUID: Double] = [:]
    var jobStarted: [UUID: Date] = [:]
    /// Work in all three workspaces, for the Dock tile.
    var activity: AppActivity {
        let processingItems = processing.records.filter { $0.state == .waiting || $0.state == .processing }
        let fraction = jobs.first { $0.state == .generating }.flatMap { jobProgress[$0.id] }
            ?? processingItems.first { $0.state == .processing }.flatMap { processing.progress[$0.id] }
        return AppActivity(count: jobs.count + processingItems.count, fraction: fraction)
    }
    var aceModel: ACEModel { ACEModel(rawValue: selectedModels[.ace] ?? "") ?? .turbo }
    var adapterURLs: [EngineID: URL] = [:]
    var adapterStrengths: [EngineID: Double] = [:]
    var lora: URL? {
        get { adapterURLs[selectedEngine] }
        set { adapterURLs[selectedEngine] = newValue; preferences.set(newValue?.path, forKey: "adapter-" + selectedEngine.rawValue) }
    }
    var loraScale: Double {
        get { adapterStrengths[selectedEngine] ?? 1 }
        set { adapterStrengths[selectedEngine] = newValue; preferences.set(newValue, forKey: "adapter-strength-" + selectedEngine.rawValue) }
    }
    var availableACEModels: [ACEModel] = [.turbo]
    private var activeEngine: (any GenerationEngine)?
    func engine(for id: EngineID) -> any GenerationEngine {
        switch id { case .ace: ace; case .miniMax: miniMax; default: pythonEngines[id]! }
    }
    var player = AudioPlayer()
    private let persistence: LibraryPersistence
    private let audioFiles = AudioFiles()
    var generations: [Generation] = []
    var selectedID: UUID? { didSet { loadSelected() } }
    var prompt = ""
    var lyrics = ""
    var avoid = "drums, percussion, vocals, beat"
    var duration: Double = 30
    var seedText = ""
    var instrumental = true
    var noPercussion = true
    var noVocals = true
    var steps = 8
    var referenceStrength = 0.5
    var mode: GenerationMode = .generate
    var reference: URL?
    var inspectorVisible = false
    var showQueue = true
    var engineStatus = "Not Installed"
    var engineProgress: Double?
    var engineBusy = false
    var error: String?
    var installed: Bool { modelInstalled(selectedEngine, model: modelID) }
    var ready = false
    var promptFocused = false
    var outputDirectory: URL { didSet { preferences.set(outputDirectory.path, forKey: "outputDirectory"); processing.outputDirectory = outputDirectory } }
    var diskUsage: Int64 = 0
    private var engineTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var activeID: UUID?
    private var cancelling = false
    private var stopping = false
    private var history: [String] = []
    private var historyIndex: Int?
    private var historyDraft = ""
    var selected: Generation? { generations.first { $0.id == selectedID } }
    var jobs: [Generation] { generations.filter { $0.state == .waiting || $0.state == .generating }.sorted { $0.created < $1.created } }
    var canGenerate: Bool {
        installed && ProcessInfo.processInfo.physicalMemory >= UInt64(minimumMemoryGB) * 1_073_741_824 && !engineBusy && !stopping &&
        (!generateBoth || !supportsDualQueue || mode != .generate || (modelInstalled(.ace, model: selectedModels[.ace]!) && modelInstalled(.miniMax, model: selectedModels[.miniMax]!))) &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (seedText.isEmpty || (Int64(seedText).map { $0 >= 0 } ?? false)) &&
        (mode != .repaint || (player.selection != nil && player.url != nil))
    }
    init(paths: AppPaths = .standard, preferences: UserDefaults = .standard) {
        self.paths = paths; self.preferences = preferences
        manifest = try! EngineManifest.bundled()
        ace = ACEEngine(paths: paths, manifest: manifest)
        miniMax = MiniMaxEngine(paths: paths, manifest: try! .bundled())
        catalog = try! RuntimeCatalog.bundled()
        let enginePaths = paths
        pythonEngines = Dictionary(uniqueKeysWithValues: (catalog.runtimes + (try! ProcessingCatalog.bundled()).runtimes).map { ($0.id, PythonEngine(paths: enginePaths, spec: $0)) })
        persistence = LibraryPersistence(paths: paths)
        exportSettings = ExportSettings(defaults: preferences)
        takes = [1, 2, 4].contains(preferences.integer(forKey: "takes")) ? preferences.integer(forKey: "takes") : 1
        let savedOutput = preferences.string(forKey: "outputDirectory")
            ?? preferences.persistentDomain(forName: "com.generativeaudio.app")?["outputDirectory"] as? String
        let initialOutput = savedOutput.map { URL(fileURLWithPath: $0) } ?? AppPaths.defaultOutput
        outputDirectory = initialOutput
        processing = ProcessingStore(paths: paths, runtimes: pythonEngines, scheduler: scheduler, outputDirectory: initialOutput, exportSettings: exportSettings)
        selectedEngine = EngineID(rawValue: preferences.string(forKey: "engine") ?? "ace") ?? .ace
        if !EngineID.generationCases.contains(selectedEngine) { selectedEngine = .ace }
        let savedPreset = preferences.string(forKey: "miniMaxPreset") ?? "efficient"
        if miniMax.manifest.availablePresets.contains(where: { $0.id == savedPreset }) { miniMax.presetID = savedPreset }
        ace.modelID = preferences.string(forKey: "aceModel") ?? ACEModel.turbo.rawValue
        for id in [EngineID.ace, .stableAudio] {
            if let path = preferences.string(forKey: "adapter-" + id.rawValue) ?? (id == .ace ? preferences.string(forKey: "aceLoRA") : nil) { adapterURLs[id] = URL(fileURLWithPath: path) }
            adapterStrengths[id] = preferences.object(forKey: "adapter-strength-" + id.rawValue) as? Double ?? 1
        }
        for id in EngineID.allCases {
            let fallback = id == .ace ? ace.modelID : id == .miniMax ? miniMax.presetID : pythonEngines[id]!.modelID
            let saved = preferences.string(forKey: "model-" + id.rawValue) ?? fallback
            selectedModels[id] = models(for: id).contains { $0.id == saved } ? saved : fallback
        }
        processing.beforeRun = { [weak self] in
            guard let self else { return }
            for id in EngineID.generationCases { await self.engine(for: id).stop() }
        }
        refreshACEModels()
        steps = currentModel.steps
        ace.onExit = { [weak self] in if self?.selectedEngine == .ace { self?.ready = false; self?.engineStatus = "Stopped" } }
        miniMax.onExit = { [weak self] in if self?.selectedEngine == .miniMax { self?.ready = false; self?.engineStatus = "Stopped" } }
        Task {
            do { generations = try await persistence.load(); history = generations.reversed().map { $0.request.prompt }; selectedID = generations.first(where: { $0.state == .ready })?.id }
            catch { self.error = "The library could not be loaded. \(error.localizedDescription)" }
            ready = installed; engineStatus = installed ? "Available" : "Choose models in Settings"
            inspectorVisible = installed
            await measureDisk()
        }
    }
    func selectEngine(_ id: EngineID) {
        guard EngineID.generationCases.contains(id), id != selectedEngine, canSwitchEngine else { return }
        selectedEngine = id; preferences.set(id.rawValue, forKey: "engine")
        mode = .generate; ready = installed; steps = currentModel.steps
        duration = max(duration, id.minimumDuration)
        if !supportsDualQueue { generateBoth = false }
        if activeID == nil { engineStatus = installed ? "Available" : "Choose models in Settings" }
        Task { await measureDisk() }
    }
    func selectModel(_ id: String) {
        guard canSwitchEngine, let model = models(for: selectedEngine).first(where: { $0.id == id }) else { return }
        selectedModels[selectedEngine] = id
        preferences.set(id, forKey: "model-" + selectedEngine.rawValue)
        steps = model.steps; ready = installed
        if selectedEngine == .ace || selectedEngine == .stableAudio { lora = nil }
        if activeID == nil { engineStatus = installed ? "Available" : "Download model in Settings" }
    }
    func refreshACEModels() {
        availableACEModels = ACEModel.allCases.filter { model in
            model == .turbo || FileManager.default.fileExists(atPath: paths.models.appendingPathComponent(model.rawValue).appendingPathComponent("config.json").path)
        }
        if !availableACEModels.contains(where: { $0.rawValue == ace.modelID }) { ace.modelID = ACEModel.turbo.rawValue }
    }
    func selectACEModel(_ id: String) { selectModel(id) }
    func importACEModel() {
        guard canSwitchEngine else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.begin { response in Task { @MainActor in
            guard response == .OK, let source = panel.url else { return }
            do {
                guard let model = ACEModel(rawValue: source.lastPathComponent) else { throw AppError.message("Choose a checkpoint folder named acestep-v15-turbo, acestep-v15-sft, acestep-v15-xl-turbo or acestep-v15-xl-sft.") }
                let destination = self.paths.models.appendingPathComponent(model.rawValue)
                try await Task.detached { try ACECheckpointImporter.copy(source, to: destination) }.value
                try Task.checkCancellation()
                self.refreshACEModels()
                await self.measureDisk()
            } catch { self.error = error.localizedDescription }
        } }
    }
    func chooseLoRA() {
        guard canSwitchEngine else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.begin { response in Task { @MainActor in
            guard response == .OK, let url = panel.url else { return }
            self.lora = url
        } }
    }
    func clearLoRA() { lora = nil }
    func selectPreset(_ id: String) { selectModel(id) }
    func installEngine() { downloadModel(selectedEngine, model: modelID) }
    func startEngine() { ready = installed; engineStatus = installed ? "Available" : "Choose models in Settings" }
    func restartEngine() {
        guard jobs.isEmpty, scheduler.owner == nil, !engineBusy, installed else { return }
        let id = selectedEngine; let model = modelID; let worker = engine(for: id)
        engineBusy = true; ready = false; engineStatus = "Preparing…"
        engineTask = Task {
            do {
                let lease = UUID()
                try await scheduler.acquire(lease)
                defer { scheduler.release(lease) }
                for other in EngineID.allCases { await engine(for: other).stop() }
                await configure(worker, id: id, model: model)
                try await worker.start(); ready = installed; engineStatus = "Available"
            }
            catch { engineStatus = "Stopped"; self.error = error.localizedDescription }
            engineBusy = false
        }
    }
    func cancelInstall() { downloads.cancel(selectedEngine, model: modelID) }
    func uninstall(_ id: EngineID? = nil) {
        let target = id ?? selectedEngine
        guard !processing.busy(target), !downloads.active(target), !jobs.contains(where: { $0.resolvedEngineID == target }), !engineBusy else { return }
        let worker = engine(for: target)
        Task {
            await worker.stop()
            do { try FileManager.default.removeItem(at: worker.directory); try paths.prepare(); if target == selectedEngine { ready = false; engineStatus = "Choose models in Settings" } }
            catch { self.error = "Engine files could not be removed. \(error.localizedDescription)" }
            refreshACEModels(); await measureDisk()
        }
    }
    func generate() {
        guard canGenerate else { return }
        let seed = Int64(seedText) ?? Int64.random(in: 0...Int64(Int32.max))
        var request = GenerationRequest()
        request.prompt = prompt; request.avoid = avoid; request.duration = mode == .repaint ? player.duration : duration
        request.seed = seed; request.instrumental = instrumental; request.noPercussion = noPercussion; request.noVocals = noVocals
        request.model = modelID; request.steps = steps; request.referenceStrength = referenceStrength; request.reference = engine.capabilities.referenceAudio ? reference : nil; request.mode = mode
        if mode == .repaint { request.source = player.url; request.region = player.selection }
        let name = String(prompt.prefix(160)).split(whereSeparator: { $0.isWhitespace || $0 == "," }).prefix(3).joined(separator: " ")
        if selectedEngine == .ace || selectedEngine == .stableAudio || generateBoth {
            let adapterEngine: EngineID = supportsDualQueue ? .ace : selectedEngine
            request.lora = adapterURLs[adapterEngine]; request.loraScale = adapterStrengths[adapterEngine] ?? 1
        }
        if selectedEngine == .yue { request.lyrics = lyrics }
        let seeds = GenerationPlan.seeds(first: seed, takes: takes)
        for (take, takeSeed) in seeds.enumerated() {
            request.seed = takeSeed
            let targets = GenerationPlan.requests(base: request, selected: selectedEngine, both: generateBoth && mode == .generate, aceModel: aceModel, miniMaxModel: selectedModels[.miniMax]!, miniMaxSteps: models(for: .miniMax).first { $0.id == selectedModels[.miniMax] }!.steps)
            for (id, snapshot) in targets {
                var generation = Generation(name: seeds.count > 1 ? "\(name) take \(take + 1)" : name, request: snapshot)
                generation.engineVersion = engine(for: id).version
                generation.engine = id.name; generation.engineID = id
                generations.insert(generation, at: 0)
                persist(generation)
            }
        }
        if history.last != prompt { history.append(prompt) }; historyIndex = nil
        Notifier.prepare()
        showQueue = true
        runQueue()
    }
    private func runQueue() {
        guard queueTask == nil, !cancelling, !stopping else { return }
        queueTask = Task {
            var finished: [String] = [], failed = 0
            while let item = jobs.first(where: { $0.state == .waiting }) {
                if Task.isCancelled { break }
                let id = item.resolvedEngineID
                let worker = engine(for: id)
                activeEngine = worker
                activeID = item.id
                do {
                    engineStatus = "Waiting for audio processing"
                    try await scheduler.acquire(item.id)
                    defer { scheduler.release(item.id) }
                    try Task.checkCancellation()
                    update(item.id) { $0.state = .generating }
                    jobStarted[item.id] = Date()
                    for other in EngineID.allCases where other != id { await engine(for: other).stop() }
                    try Task.checkCancellation()
                    await configure(worker, id: id, model: item.request.model)
                    engineStatus = "Preparing \(id.name)…"
                    try await worker.start()
                    try Task.checkCancellation()
                    ready = installed
                    engineStatus = "Generating · \(id.name)"
                    if id == .ace { try await ace.configureLoRA(item.request) }
                    let job = try await worker.generate(item.request)
                    update(item.id) { $0.taskID = job.id }
                    var result: EngineResult?
                    while result == nil {
                        try Task.checkCancellation()
                        result = try await worker.result(job)
                        jobProgress[item.id] = worker.jobProgress
                        if result == nil { try await Task.sleep(for: .seconds(2)) }
                    }
                    try Task.checkCancellation()
                    guard let result else { break }
                    let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"
                    let time = DateFormatter(); time.dateFormat = "HH-mm-ss"
                    let safeName = AudioFilename.safe(generations.first { $0.id == item.id }?.name ?? item.name)
                    let target = outputDirectory.appendingPathComponent(date.string(from: item.created)).appendingPathComponent("\(time.string(from: item.created)) \(safeName) \(item.id.uuidString.prefix(8)).wav")
                    try await worker.download(result, to: target)
                    try await audioFiles.prepareGeneratedWAV(target)
                    try Task.checkCancellation()
                    let data = try await audioFiles.waveform(target, cache: paths.peaks.appendingPathComponent(item.id.uuidString + ".json"))
                    update(item.id) { $0.audio = target; $0.actualDuration = data.duration; $0.state = .ready; $0.backendMetadata = result.metadata }
                    selectedID = item.id
                    finished.append(generations.first { $0.id == item.id }?.name ?? item.name)
                } catch is CancellationError { update(item.id) { $0.state = .cancelled } }
                catch {
                    if !Task.isCancelled { update(item.id) { $0.state = .failed; $0.error = error.localizedDescription }; self.error = error.localizedDescription; failed += 1 }
                }
                jobProgress[item.id] = nil; jobStarted[item.id] = nil
                activeID = nil; activeEngine = nil
                if Task.isCancelled { break }
            }
            ready = installed
            engineStatus = ready ? "Available" : "Choose models in Settings"
            queueTask = nil
            if !cancelling, !stopping, jobs.contains(where: { $0.state == .waiting }) { runQueue() }
            else if !stopping { Notifier.generationsFinished(finished, failed: failed) }
        }
    }
    func cancel(_ id: UUID) {
        guard let item = generations.first(where: { $0.id == id }) else { return }
        if item.state == .waiting {
            update(id) { $0.state = .cancelled }
            if activeID == id {
                cancelling = true; let task = queueTask; task?.cancel()
                Task { await task?.value; cancelling = false; runQueue() }
            }
            return
        }
        guard activeID == id, !cancelling else { return }
        guard let worker = activeEngine else { return }
        cancelling = true; queueTask?.cancel()
        Task {
            if let taskID = item.taskID {
                do { try await worker.cancel(GenerationJob(id: taskID)) }
                catch { self.error = error.localizedDescription }
            } else if worker.ownsServer { await worker.stop() }
            ready = installed; engineStatus = ready ? "Available" : "Choose models in Settings"
            update(id) { $0.state = .cancelled }
            // Let the interrupted worker unwind before scheduling another request.
            await queueTask?.value
            cancelling = false; runQueue()
        }
    }
    private func update(_ id: UUID, _ body: (inout Generation) -> Void) {
        guard let index = generations.firstIndex(where: { $0.id == id }) else { return }
        body(&generations[index]); persist(generations[index])
    }
    private func persist(_ generation: Generation) { Task { do { try await persistence.save(generation) } catch { self.error = "Settings could not be saved. \(error.localizedDescription)" } } }
    private func loadSelected() {
        guard let selected, let audio = selected.audio else { player.load(nil, cache: nil); return }
        player.load(audio, cache: paths.peaks.appendingPathComponent(selected.id.uuidString + ".json"))
        if !selected.isImported { seedText = String(selected.request.seed) }
    }
    func duplicateSettings(_ item: Generation, variation: Bool = false) {
        let id = item.resolvedEngineID
        guard canSwitchEngine, !item.isImported else { return }
        selectEngine(id)
        guard models(for: id).contains(where: { $0.id == item.request.model }) else { error = "This generation's model is unavailable in the runtime catalog."; return }
        selectModel(item.request.model)
        let request = item.request
        prompt = request.prompt; avoid = request.avoid; duration = request.duration; instrumental = request.instrumental
        noPercussion = request.noPercussion; noVocals = request.noVocals; steps = request.steps
        referenceStrength = request.referenceStrength; reference = request.reference
        lora = request.lora; loraScale = request.loraScale ?? 1; lyrics = request.lyrics ?? ""
        seedText = variation ? "" : String(request.seed); mode = .generate
        if variation { generate() }
    }
    /// Queues a repaint of the selection without leaving the composer in Repaint mode.
    func repaintSelection() {
        guard engine.capabilities.repaint else { return }
        let previous = mode; mode = .repaint; generate(); mode = previous
    }
    /// Removes the library entry; its WAV stays on disk, so the deletion can be undone.
    func delete(_ id: UUID, undoManager: UndoManager? = nil) {
        guard let index = generations.firstIndex(where: { $0.id == id }), generations[index].state != .generating && generations[index].state != .waiting else { return }
        let item = generations.remove(at: index)
        if selectedID == id { selectedID = visibleGenerations.first?.id }
        undoManager?.registerUndo(withTarget: self) { store in MainActor.assumeIsolated { store.restore(item, undoManager: undoManager) } }
        undoManager?.setActionName("Delete Generation")
        Task {
            do { try await persistence.delete(item) }
            catch { insert(item); self.error = "This generation could not be removed. \(error.localizedDescription)" }
        }
    }
    func restore(_ item: Generation, undoManager: UndoManager? = nil) {
        guard !generations.contains(where: { $0.id == item.id }) else { return }
        insert(item); selectedID = item.id
        undoManager?.registerUndo(withTarget: self) { store in MainActor.assumeIsolated { store.delete(item.id, undoManager: undoManager) } }
        undoManager?.setActionName("Delete Generation")
        persist(item)
    }
    private func insert(_ item: Generation) {
        generations.insert(item, at: generations.firstIndex { $0.created < item.created } ?? generations.endIndex)
    }
    /// Adds audio files to the library as imported items, then selects the last one.
    func importAudio(_ urls: [URL]) {
        let audio = urls.filter { AudioFiles.acceptedExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { error = "Audiogen can import WAV, AIFF, FLAC, MP3 and M4A audio."; return }
        let folder = outputDirectory.appendingPathComponent("Imported")
        Task {
            var last: UUID?, failures: [String] = []
            for url in audio {
                let id = UUID()
                do {
                    let target = try await audioFiles.importToLibrary(url, folder: folder, id: id)
                    let waveform: WaveformData
                    do { waveform = try await audioFiles.waveform(target, cache: paths.peaks.appendingPathComponent(id.uuidString + ".json")) }
                    catch { try? FileManager.default.removeItem(at: target); throw error }
                    var request = GenerationRequest(); request.prompt = ""; request.duration = waveform.duration
                    var item = Generation(id: id, name: url.deletingPathExtension().lastPathComponent, request: request)
                    item.engine = "Imported"; item.engineVersion = ""; item.imported = true
                    item.state = .ready; item.audio = target; item.actualDuration = waveform.duration
                    try await persistence.save(item)
                    insert(item); last = id
                } catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
            if let last {
                if !visibleGenerations.contains(where: { $0.id == last }) { searchText = ""; starredOnly = false; sourceFilter = nil }
                workspace = .generate; selectedID = last
            }
            if !failures.isEmpty { error = "Some audio could not be imported.\n" + failures.joined(separator: "\n") }
        }
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = true
        panel.message = "Choose audio to add to your library."
        panel.begin { response in Task { @MainActor in if response == .OK { self.importAudio(panel.urls) } } }
    }
    /// Audio dropped on the composer becomes the reference when the engine can use one.
    func dropOnComposer(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: { AudioFiles.acceptedExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
        if engine.capabilities.referenceAudio { addReference(url) } else { importAudio(urls) }
        return true
    }
    /// The selected region as a clip, or the whole file, for dragging into a DAW or Finder.
    func dragProvider() -> NSItemProvider {
        do { return try AudioClips.dragFile(for: player).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        catch { self.error = error.localizedDescription; return NSItemProvider() }
    }
    func toggleStar(_ id: UUID) { update(id) { $0.starred = !$0.isStarred } }
    func export(_ item: Generation) {
        guard let audio = item.audio else { return }
        ExportPanel.run([(audio, item.name)], settings: exportSettings) { [weak self] error in
            if let error { self?.error = "The audio could not be exported. \(error.localizedDescription)" }
        }
    }
    /// Hands audio to another tool: Generate's reference, or Extract/Transform inputs.
    func send(_ url: URL, to destination: SendDestination) {
        switch destination {
        case .reference:
            if !engine.capabilities.referenceAudio { selectEngine(.ace) }
            guard engine.capabilities.referenceAudio else { return }
            workspace = .generate; addReference(url)
        case .extract: processing.importInput(url, engine: .sam); workspace = .extract
        case .transform: processing.importInput(url, engine: .after); workspace = .transform
        case .timbre: processing.importInput(url, engine: .after, reference: true); workspace = .transform
        }
    }
    func rename(_ id: UUID, name: String) {
        Task {
            do {
                let oldAudio = generations.first { $0.id == id }?.audio
                let renamed = try await persistence.rename(id, name: name, in: generations)
                if let oldAudio, let newAudio = renamed.first(where: { $0.id == id })?.audio, reference == oldAudio { reference = newAudio }
                // Merge changed paths into current records so active jobs keep their state.
                for item in renamed {
                    guard let index = generations.firstIndex(where: { $0.id == item.id }) else { continue }
                    if item.id == id { generations[index].name = item.name; generations[index].audio = item.audio }
                    generations[index].request.source = item.request.source
                    generations[index].request.reference = item.request.reference
                }
                if selectedID == id { loadSelected() }
                if let oldAudio, player.url == oldAudio, let audio = renamed.first(where: { $0.id == id })?.audio, oldAudio != audio {
                    player.load(audio, cache: paths.peaks.appendingPathComponent(id.uuidString + ".json"))
                }
            } catch { self.error = "The generation could not be renamed. \(error.localizedDescription)" }
        }
    }
    func addReference(_ url: URL) {
        Task {
            do {
                let converted = try await audioFiles.importReference(url, directory: paths.references)
                reference = converted
                if selected?.audio == nil { player.load(converted, cache: paths.peaks.appendingPathComponent(converted.deletingLastPathComponent().lastPathComponent + ".json")) }
            } catch { self.error = "Reference audio could not be imported. \(error.localizedDescription)" }
        }
    }
    func clearReference() {
        reference = nil
        if selected?.audio == nil { player.load(nil, cache: nil) }
    }
    func chooseReference() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.begin { response in Task { @MainActor in if response == .OK, let url = panel.url { self.addReference(url) } } }
    }
    func chooseOutputDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.begin { response in Task { @MainActor in if response == .OK, let url = panel.url { self.outputDirectory = url } } }
    }
    func navigatePromptHistory(_ delta: Int) {
        guard !history.isEmpty else { return }
        if historyIndex == nil { historyDraft = prompt }
        let next = min(history.count, max(0, (historyIndex ?? history.count) + delta))
        historyIndex = next; prompt = next == history.count ? historyDraft : history[next]
    }
    func reveal(_ url: URL?) { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func copyPrompt(_ generation: Generation) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(generation.request.prompt, forType: .string) }
    func checkUpdates() {
        Task {
            do {
                if selectedEngine == .miniMax {
                    error = "MiniMax uses the verified runtime bundled with Audiogen (\(miniMax.version)). Runtime updates arrive with Audiogen updates; installed models are pinned separately."
                    return
                }
                let url = URL(string: "https://api.github.com/repos/ace-step/ACE-Step-1.5/releases/latest")!
                let (bytes, _) = try await URLSession.shared.data(from: url)
                let data = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                guard let tag = data?["tag_name"] as? String else { throw AppError.message("Could not check for engine updates.") }
                error = tag == manifest.version ? "The engine is up to date with the current upstream release." : "Upstream \(tag) is available. This app uses verified \(manifest.version); a validated manifest is required before updating."
            } catch { self.error = error.localizedDescription }
        }
    }
    func measureDisk() async {
        let root = engine.directory
        diskUsage = await Task.detached { Self.directorySize(root) }.value
    }
    nonisolated private static func directorySize(_ root: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true { total += Int64(values.fileAllocatedSize ?? 0) }
        }
        return total
    }

    func shutdown() { stopping = true; processing.shutdown(); engineTask?.cancel(); queueTask?.cancel(); downloads.cancelAll(); for id in EngineID.allCases { engine(for: id).terminateOwnedProcess() } }
    func shutdownGracefully() async {
        shutdown()
        for id in EngineID.allCases { await engine(for: id).stop() }
        await downloads.finish()
        await engineTask?.value
        await queueTask?.value
        await processing.finish()
    }
}
