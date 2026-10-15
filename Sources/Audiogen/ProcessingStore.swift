import Foundation
import AppKit
import AVFoundation
import Observation

@MainActor @Observable final class ProcessingDraft {
    let engine: EngineID
    var model: String
    var source: URL?
    var reference: URL?
    var duration = 0.0
    var sourceChannels = 1
    var stereo = true
    var sound = ""
    var anchors: [ExtractionAnchor] = []
    var steps: Int
    var seedText = ""
    var guidance = 1.0
    var importing = false
    var selectedID: UUID?
    var auditionRole: AudioOutputRole?
    let sourcePlayer = AudioPlayer()
    let referencePlayer = AudioPlayer()
    let auditionPlayer = AudioPlayer()
    var importToken = UUID()
    init(engine: EngineID, model: RuntimeModel) { self.engine = engine; self.model = model.id; steps = model.steps }
    func request() throws -> ProcessingRequest {
        guard let source else { throw AppError.message("Choose source audio.") }
        guard seedText.isEmpty || Int64(seedText) != nil else { throw AppError.message("Enter a nonnegative seed, or leave it empty.") }
        let request = ProcessingRequest(engine: engine, model: model, source: source, reference: reference,
            description: sound, anchors: anchors, steps: steps, seed: Int64(seedText) ?? Int64.random(in: 0...Int64(Int32.max)), guidance: guidance, duration: duration,
            stereo: stereo && sourceChannels > 1)
        try request.validate(); return request
    }
    func pausePlayers() { for player in [sourcePlayer, referencePlayer, auditionPlayer] where player.isPlaying { player.toggle() } }
}

@MainActor @Observable final class ProcessingStore {
    let paths: AppPaths
    let scheduler: AudioWorkScheduler
    let runtimes: [EngineID: PythonEngine]
    let extract: ProcessingDraft
    let transform: ProcessingDraft
    var records: [ProcessingRecord] = []
    var status: [UUID: String] = [:]
    var progress: [UUID: Double] = [:]
    var error: String?
    var outputDirectory: URL
    var beforeRun: (@MainActor () async -> Void)?
    let exportSettings: ExportSettings
    private let persistence: ProcessingPersistence
    private let files = AudioFiles()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopping = false
    init(paths: AppPaths, runtimes: [EngineID: PythonEngine], scheduler: AudioWorkScheduler, outputDirectory: URL, exportSettings: ExportSettings = ExportSettings()) {
        self.paths = paths; self.runtimes = runtimes; self.scheduler = scheduler; self.outputDirectory = outputDirectory; self.exportSettings = exportSettings
        persistence = ProcessingPersistence(paths: paths)
        extract = ProcessingDraft(engine: .sam, model: runtimes[.sam]!.spec.models[0])
        transform = ProcessingDraft(engine: .after, model: runtimes[.after]!.spec.models[0])
        Task {
            do { records = try await persistence.load() }
            catch { self.error = "Processing history could not be loaded. \(error.localizedDescription)" }
        }
    }
    func draft(_ id: EngineID) -> ProcessingDraft { id == .sam ? extract : transform }
    func record(_ draft: ProcessingDraft) -> ProcessingRecord? { records.first { $0.id == draft.selectedID } }
    func busy(_ engine: EngineID) -> Bool { records.contains { $0.request.engine == engine && ($0.state == .waiting || $0.state == .processing) } }
    func canRun(_ id: EngineID) -> Bool {
        let draft = draft(id)
        guard !stopping, !draft.importing, let model = runtimes[id]?.spec.models.first(where: { $0.id == draft.model }),
              runtimes[id]!.isInstalled(model), ProcessInfo.processInfo.physicalMemory >= UInt64(model.minimumMemoryGB) * 1_073_741_824 else { return false }
        return (try? draft.request()) != nil
    }
    func chooseInput(_ id: EngineID, reference: Bool = false) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        panel.message = reference ? "Choose audio with the timbre you want to transfer." : "Choose the audio to process."
        panel.begin { [weak self] result in if result == .OK, let url = panel.url { Task { @MainActor in self?.importInput(url, engine: id, reference: reference) } } }
    }
    func importInput(_ url: URL, engine: EngineID, reference: Bool = false) {
        let draft = draft(engine); let token = UUID(); draft.importToken = token; draft.importing = true
        Task {
            defer { if draft.importToken == token { draft.importing = false } }
            do {
                let copy = try await files.importReference(url, directory: paths.references)
                let audio = try AVAudioFile(forReading: copy)
                let duration = Double(audio.length) / audio.processingFormat.sampleRate
                guard duration.isFinite, duration > 0 else { throw AppError.message("Choose a nonempty audio file.") }
                if reference && duration > 30 { throw AppError.message("Choose a timbre reference of 30 seconds or less.") }
                guard draft.importToken == token else { return }
                draft.pausePlayers(); draft.selectedID = nil; draft.auditionPlayer.load(nil, cache: nil)
                if reference { draft.reference = copy; draft.referencePlayer.load(copy, cache: cache(copy)) }
                else { draft.source = copy; draft.duration = duration; draft.sourceChannels = Int(audio.fileFormat.channelCount); draft.anchors = []; draft.sourcePlayer.load(copy, cache: cache(copy)) }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func cache(_ url: URL) -> URL { paths.peaks.appendingPathComponent("processing-" + url.deletingLastPathComponent().lastPathComponent + "-" + url.lastPathComponent + ".json") }
    func addAnchor(present: Bool) {
        guard extract.duration <= 30, extract.anchors.count < 3, let region = extract.sourcePlayer.selection, region.duration > 0 else { return }
        extract.anchors.append(ExtractionAnchor(present: present, region: region)); extract.sourcePlayer.selection = nil
    }
    func enqueue(_ id: EngineID) {
        guard canRun(id), let engine = runtimes[id] else { return }
        let request: ProcessingRequest
        do { request = try draft(id).request() } catch { self.error = error.localizedDescription; return }
        let item = ProcessingRecord(name: request.source.deletingPathExtension().lastPathComponent + (id == .sam ? " — " + request.description : " — transformed"), request: request, sourceRevision: engine.spec.revision)
        records.insert(item, at: 0); draft(id).selectedID = item.id
        Notifier.prepare()
        let destination = outputDirectory.appendingPathComponent("Processed").appendingPathComponent(item.id.uuidString)
        tasks[item.id] = Task { [self] in
            var hasLease = false
            defer { if hasLease { scheduler.release(item.id) }; tasks[item.id] = nil; progress[item.id] = nil; status[item.id] = nil }
            do {
                try await persistence.save(item)
                status[item.id] = "Waiting for other audio processing"
                try await scheduler.acquire(item.id); hasLease = true
                try Task.checkCancellation()
                await beforeRun?()
                try Task.checkCancellation()
                engine.modelID = request.model
                update(item.id) { $0.state = .processing }
                status[item.id] = "Preparing \(id.name)"
                let job = try await engine.process(request)
                var result: (ProcessingWorkerResult, URL, String)?
                while result == nil {
                    try Task.checkCancellation()
                    if let (label, fraction) = engine.processingProgress() { status[item.id] = label; progress[item.id] = fraction }
                    result = try engine.processingResult(job)
                    if result == nil { try await Task.sleep(for: .milliseconds(500)) }
                }
                try Task.checkCancellation()
                guard let (output, root, metadata) = result else { return }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var artifacts: [ProcessingOutput] = []
                do {
                    for file in output.outputs {
                        let target = destination.appendingPathComponent(AudioFilename.safe(item.name) + " — " + file.role.rawValue + ".wav")
                        try FileManager.default.copyItem(at: root.appendingPathComponent(file.filename), to: target)
                        try await files.prepareGeneratedWAV(target)
                        let audio = try AVAudioFile(forReading: target)
                        artifacts.append(ProcessingOutput(role: file.role, file: target, duration: Double(audio.length) / audio.processingFormat.sampleRate))
                    }
                    try Task.checkCancellation()
                    var completed = records.first { $0.id == item.id } ?? item
                    completed.state = .ready; completed.outputs = artifacts; completed.metadata = metadata
                    try await persistence.save(completed)
                    if let index = records.firstIndex(where: { $0.id == item.id }) { records[index] = completed }
                    engine.finishProcessing()
                    if draft(id).selectedID == item.id { audition(id, role: artifacts.first?.role) }
                    Notifier.processingFinished(item.name, extraction: id == .sam, failed: false)
                } catch { try? FileManager.default.removeItem(at: destination); throw error }
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                update(item.id) { $0.state = cancelled ? .cancelled : .failed; $0.error = cancelled ? nil : error.localizedDescription }
                if !cancelled { self.error = error.localizedDescription; Notifier.processingFinished(item.name, extraction: id == .sam, failed: true) }
            }
            if hasLease { await engine.stop() }
        }
    }
    private func update(_ id: UUID, body: (inout ProcessingRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index]); let record = records[index]
        Task { do { try await persistence.save(record) } catch { self.error = error.localizedDescription } }
    }
    func cancel(_ id: UUID) { tasks[id]?.cancel() }
    func select(_ item: ProcessingRecord) {
        let draft = draft(item.request.engine); draft.pausePlayers(); draft.selectedID = item.id
        draft.source = item.request.source; draft.reference = item.request.reference; draft.duration = item.request.duration
        draft.model = item.request.model; draft.sound = item.request.description; draft.anchors = item.request.anchors
        draft.steps = item.request.steps; draft.seedText = String(item.request.seed); draft.guidance = item.request.guidance
        draft.sourceChannels = (try? AVAudioFile(forReading: item.request.source)).map { Int($0.fileFormat.channelCount) } ?? 1
        draft.stereo = item.request.stereo ?? (draft.sourceChannels == 1)
        draft.sourcePlayer.load(draft.source, cache: cache(item.request.source))
        if let reference = item.request.reference { draft.referencePlayer.load(reference, cache: cache(reference)) }
        audition(draft.engine, role: item.outputs.first?.role)
    }
    func audition(_ id: EngineID, role: AudioOutputRole?) {
        let draft = draft(id); let item = record(draft)
        let url = role.flatMap { role in item?.outputs.first { $0.role == role }?.file } ?? (role == nil ? item?.request.source ?? draft.source : nil)
        let time = draft.auditionPlayer.time; let playing = draft.auditionPlayer.isPlaying
        draft.pausePlayers(); draft.auditionRole = role
        draft.auditionPlayer.load(url, cache: url.map(cache), at: time, autoplay: playing)
    }
    /// Removes the history entry; output files stay on disk, so the removal can be undone.
    func remove(_ item: ProcessingRecord, undoManager: UndoManager? = nil) {
        guard item.state != .waiting && item.state != .processing, let index = records.firstIndex(where: { $0.id == item.id }) else { return }
        records.remove(at: index)
        let draft = draft(item.request.engine)
        if draft.selectedID == item.id { draft.selectedID = nil; draft.auditionPlayer.load(nil, cache: nil) }
        undoManager?.registerUndo(withTarget: self) { store in MainActor.assumeIsolated { store.restore(item, undoManager: undoManager) } }
        undoManager?.setActionName("Remove from History")
        Task {
            do { try await persistence.remove(item) }
            catch { insert(item); self.error = error.localizedDescription }
        }
    }
    func restore(_ item: ProcessingRecord, undoManager: UndoManager? = nil) {
        guard !records.contains(where: { $0.id == item.id }) else { return }
        insert(item)
        undoManager?.registerUndo(withTarget: self) { store in MainActor.assumeIsolated { store.remove(item, undoManager: undoManager) } }
        undoManager?.setActionName("Remove from History")
        Task { do { try await persistence.save(item) } catch { self.error = error.localizedDescription } }
    }
    private func insert(_ item: ProcessingRecord) {
        records.insert(item, at: records.firstIndex { $0.created < item.created } ?? records.endIndex)
    }
    func reveal(_ url: URL?) { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func export(_ item: ProcessingRecord) {
        ExportPanel.run(item.outputs.map { ($0.file, $0.file.deletingPathExtension().lastPathComponent) }, settings: exportSettings) { [weak self] error in
            if let error { self?.error = "The audio could not be exported. \(error.localizedDescription)" }
        }
    }
    func shutdown() { stopping = true; for task in tasks.values { task.cancel() }; extract.pausePlayers(); transform.pausePlayers() }
    func finish() async { let pending = Array(tasks.values); for task in pending { await task.value } }
}
