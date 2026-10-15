import Foundation
import CryptoKit

struct RuntimeModel: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let minimumMemoryGB: Int
    let steps: Int
    let files: [EngineManifest.Artifact]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}
struct PythonRuntimeSpec: Codable, Sendable {
    let id: EngineID
    let revision: String
    let repository: EngineManifest.Artifact
    let repositoryDirectory: String
    let workingSubdirectory: String
    let models: [RuntimeModel]
}
struct RuntimeCatalog: Codable, Sendable {
    let runtimes: [PythonRuntimeSpec]
    let aceModels: [RuntimeModel]
    static var resourceRoot: URL { Bundle.module.resourceURL!.appendingPathComponent("PythonRuntimes") }
    static func bundled() throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: resourceRoot.appendingPathComponent("catalog.json"))) }
}

@MainActor final class PythonEngine: GenerationEngine {
    let id: EngineID
    let spec: PythonRuntimeSpec
    let paths: AppPaths
    let runtimeIdentity: String
    var modelID: String
    var model: RuntimeModel { spec.models.first { $0.id == modelID } ?? spec.models[0] }
    var directory: URL { paths.support.appendingPathComponent("Engines/\(id.rawValue)") }
    var repository: URL { directory.appendingPathComponent("repository") }
    var models: URL { directory.appendingPathComponent("models") }
    var environmentRoot: URL { directory.appendingPathComponent("environment") }
    var python: URL { environmentRoot.appendingPathComponent(".venv/bin/python") }
    var version: String { String(spec.revision.prefix(12)) }
    var capabilities: EngineCapabilities { EngineCapabilities(textToAudio: EngineID.generationCases.contains(id), referenceAudio: id == .stableAudio || id == .after, continuation: false, repaint: id == .stableAudio, lyrics: id == .yue, instrumental: true, stems: false) }
    var runtimeInstalled: Bool {
        (try? String(contentsOf: directory.appendingPathComponent("runtime-installed.txt"), encoding: .utf8)) == runtimeIdentity && FileManager.default.isExecutableFile(atPath: python.path)
    }
    var installed: Bool { isInstalled(model) }
    func isInstalled(_ model: RuntimeModel) -> Bool {
        runtimeInstalled && (try? JSONDecoder().decode(RuntimeModel.self, from: Data(contentsOf: directory.appendingPathComponent("\(model.id).json")))) == model && model.files.allSatisfy { file in (try? FileManager.default.attributesOfItem(atPath: models.appendingPathComponent(file.name).path)[.size] as? Int64) == file.bytes }
    }
    private var child: Process?
    private var logHandle: FileHandle?
    private var jobID: String?
    private var jobRoot: URL?
    var ownsServer: Bool { child?.isRunning == true }
    var onExit: (@MainActor () -> Void)?
    init(paths: AppPaths, spec: PythonRuntimeSpec) {
        self.paths = paths; self.spec = spec; id = spec.id; modelID = spec.models[0].id
        let lock = (try? Data(contentsOf: RuntimeCatalog.resourceRoot.appendingPathComponent(spec.id.rawValue).appendingPathComponent("uv.lock"))) ?? Data()
        runtimeIdentity = spec.revision + "/" + SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined()
    }
    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"] { env.removeValue(forKey: key) }
        env["PYTHONUNBUFFERED"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"; env["DO_NOT_TRACK"] = "1"
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"; env["MLX_ENABLE_TF32"] = "0"
        env["HF_HOME"] = directory.appendingPathComponent("hf-cache").path
        return env
    }
    func install(progress: @escaping @MainActor (String, Double?) -> Void) async throws { try await install(modelID: modelID, progress: progress) }
    func installRuntime(progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        if runtimeInstalled { return }
        try paths.prepare()
        let runtime = directory.appendingPathComponent("runtime")
        let downloads = directory.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: environmentRoot, withIntermediateDirectories: true)
        let base = try EngineManifest.bundled()
        let py = try JSONDecoder().decode(EngineManifest.Artifact.self, from: Data(contentsOf: RuntimeCatalog.resourceRoot.appendingPathComponent("python312.json")))
        for artifact in [base.runtime, py, spec.repository] {
            try Task.checkCancellation()
            try await ArtifactDownloader().fetch(artifact, to: downloads.appendingPathComponent(artifact.name), downloads: downloads, progress: progress)
        }
        let runner = ProcessRunner()
        let log = paths.logs.appendingPathComponent("\(id.rawValue)-installation.log")
        var env = environment; env.removeValue(forKey: "HF_HUB_OFFLINE"); env.removeValue(forKey: "TRANSFORMERS_OFFLINE")
        env["UV_PYTHON_DOWNLOADS"] = "never"
        env["UV_CACHE_DIR"] = paths.support.appendingPathComponent("RuntimeCache/uv").path
        let standalone = runtime.appendingPathComponent("python/bin/python3")
        let uv = runtime.appendingPathComponent("uv-aarch64-apple-darwin/uv")
        progress("Unpacking runtime", nil)
        for (artifact, sentinel) in [(base.runtime, uv), (py, standalone)] where !FileManager.default.fileExists(atPath: sentinel.path) {
            try await runner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", downloads.appendingPathComponent(artifact.name).path, "-C", runtime.path], directory: directory, environment: env, log: log)
        }
        if !FileManager.default.fileExists(atPath: repository.path) {
            try await runner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", downloads.appendingPathComponent(spec.repository.name).path, "-C", directory.path], directory: directory, environment: env, log: log)
            try FileManager.default.moveItem(at: directory.appendingPathComponent(spec.repositoryDirectory), to: repository)
        }
        for file in ["pyproject.toml", "uv.lock"] {
            let destination = environmentRoot.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: RuntimeCatalog.resourceRoot.appendingPathComponent(id.rawValue).appendingPathComponent(file), to: destination)
        }
        progress("Installing dependencies · see \(log.lastPathComponent)", nil)
        try await runner.run(uv, ["sync", "--frozen", "--no-dev", "--no-install-project", "--python", standalone.path, "--no-python-downloads"], directory: environmentRoot, environment: env, log: log)
        progress("Checking runtime", nil)
        let modules: String
        switch id {
        case .after: modules = "torch, soundfile, scipy"
        case .sam: modules = "mlx.core, transformers, soundfile, scipy, sentencepiece"
        case .stableAudio: modules = "mlx.core, soundfile, sentencepiece"
        case .musicGen: modules = "mlx.core, torch, transformers, omegaconf, sentencepiece, soundfile"
        default: modules = "mlx.core, mlx_lm, transformers, safetensors, tiktoken, soundfile"
        }
        try await runner.run(python, ["-c", "import \(modules)"], directory: directory, environment: environment, log: log)
        try runtimeIdentity.write(to: directory.appendingPathComponent("runtime-installed.txt"), atomically: true, encoding: .utf8)
    }
    func install(modelID: String, progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        guard let chosen = spec.models.first(where: { $0.id == modelID }) else { throw AppError.message("Unknown model.") }
        try await installRuntime(progress: progress)
        try await Self.installFiles(chosen.files, root: models, downloads: directory.appendingPathComponent("downloads"), progress: progress)
        try JSONEncoder().encode(chosen).write(to: directory.appendingPathComponent("\(chosen.id).json"), options: .atomic)
    }
    static func installFiles(_ files: [EngineManifest.Artifact], root: URL, downloads: URL, progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = files.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0.name).path) }.reduce(Int64(0)) { $0 + $1.bytes }
        if let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, free < missing + 1_000_000_000 { throw AppError.message("There is not enough disk space. Free up \(ByteCountFormatter.string(fromByteCount: missing + 1_000_000_000, countStyle: .file)).") }
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }; var completed: Int64 = 0
        for artifact in files {
            try Task.checkCancellation()
            try await ArtifactDownloader().fetch(artifact, to: root.appendingPathComponent(artifact.name), downloads: downloads) { status, fraction in
                progress(status, fraction.map { (Double(completed) + $0 * Double(artifact.bytes)) / Double(max(1, total)) })
            }
            completed += artifact.bytes
        }
    }
    func start() async throws {
        guard installed else { throw AppError.message("Download this model in Settings → Runtimes before generating.") }
        guard ProcessInfo.processInfo.physicalMemory >= UInt64(model.minimumMemoryGB) * 1_073_741_824 else { throw AppError.message("This model requires \(model.minimumMemoryGB) GB unified memory.") }
    }
    func health() async -> Bool { installed }
    func generate(_ request: GenerationRequest) async throws -> GenerationJob {
        guard !ownsServer, request.model == modelID else { throw AppError.message("The requested model is unavailable or already generating.") }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.duration > 0, request.seed >= 0 else { throw AppError.message("Enter a prompt, duration and valid seed.") }
        if request.mode == .repaint {
            guard id == .stableAudio, request.source != nil, let region = request.region, region.start >= 0, region.end > region.start, region.end <= request.duration else { throw AppError.message("Choose a valid source region to repaint.") }
        }
        try await start()
        let job = UUID().uuidString
        let root = directory.appendingPathComponent("jobs/\(job)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        struct Configuration: Encodable {
            let engine: EngineID; let sourceRevision: String; let request: GenerationRequest
            let sourceRoot: String; let modelRoot: String; let output: String; let metadata: String
        }
        let configuration = Configuration(engine: id, sourceRevision: spec.revision, request: request, sourceRoot: repository.appendingPathComponent(spec.workingSubdirectory).path, modelRoot: models.path, output: root.appendingPathComponent("audio.wav").path, metadata: root.appendingPathComponent("result.json").path)
        let input = root.appendingPathComponent("request.json")
        try JSONEncoder().encode(configuration).write(to: input, options: .atomic)
        return try launch(input: input, root: root, job: job, worker: "worker.py")
    }
    private func launch(input: URL, root: URL, job: String, worker: String) throws -> GenerationJob {
        try Task.checkCancellation()
        let process = Process(); process.executableURL = python
        process.arguments = [RuntimeCatalog.resourceRoot.appendingPathComponent(worker).path, input.path]
        process.currentDirectoryURL = repository; process.environment = environment
        let log = paths.logs.appendingPathComponent("\(id.rawValue).log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
        process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
        try process.run(); child = process; logHandle = handle; jobID = job; jobRoot = root
        return GenerationJob(id: job)
    }
    func process(_ request: ProcessingRequest) async throws -> GenerationJob {
        try request.validate()
        guard request.engine == id, request.model == modelID, !ownsServer else { throw AppError.message("The requested processing model is unavailable or already running.") }
        try await start()
        let job = UUID().uuidString
        let root = directory.appendingPathComponent("jobs/" + job)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        struct Configuration: Encodable {
            let request: ProcessingRequest
            let sourceRoot: String; let modelRoot: String; let outputRoot: String
        }
        let configuration = Configuration(request: request, sourceRoot: repository.path, modelRoot: models.path, outputRoot: root.path)
        let input = root.appendingPathComponent("request.json")
        try JSONEncoder().encode(configuration).write(to: input, options: .atomic)
        return try launch(input: input, root: root, job: job, worker: "processing_worker.py")
    }
    func processingProgress() -> (String, Double?)? {
        struct Progress: Decodable { let status: String; let fraction: Double? }
        guard let root = jobRoot, let bytes = try? Data(contentsOf: root.appendingPathComponent("progress.json")),
              let progress = try? JSONDecoder().decode(Progress.self, from: bytes) else { return nil }
        return (progress.status, progress.fraction)
    }
    func processingResult(_ job: GenerationJob) throws -> (ProcessingWorkerResult, URL, String)? {
        guard job.id == jobID, let child, let root = jobRoot else { throw AppError.message("This processing job is no longer available.") }
        if child.isRunning { return nil }
        try? logHandle?.close(); logHandle = nil
        guard child.terminationStatus == 0 else { throw AppError.message("\(id.name) could not process this audio. See \(id.rawValue).log in Settings → General → Diagnostics.") }
        let data = try Data(contentsOf: root.appendingPathComponent("result.json"))
        let result = try JSONDecoder().decode(ProcessingWorkerResult.self, from: data)
        let expected: Set<AudioOutputRole> = id == .sam ? [.extracted, .remaining] : [.transformed]
        guard Set(result.outputs.map(\.role)) == expected, result.outputs.count == expected.count,
              result.outputs.allSatisfy({ !$0.filename.contains("/") && !$0.filename.contains("..") && $0.filename.hasSuffix(".wav") && FileManager.default.fileExists(atPath: root.appendingPathComponent($0.filename).path) }) else { throw AppError.message("The runtime returned incomplete audio results.") }
        return (result, root, String(decoding: data, as: UTF8.self))
    }
    func finishProcessing() { if let root = jobRoot { try? FileManager.default.removeItem(at: root) }; jobRoot = nil }
    func result(_ job: GenerationJob) async throws -> EngineResult? {
        guard job.id == jobID, let child, let root = jobRoot else { throw AppError.message("This generation is no longer available.") }
        if child.isRunning { return nil }
        try? logHandle?.close(); logHandle = nil
        guard child.terminationStatus == 0 else { throw AppError.message("\(id.name) could not generate this audio. Open \(id.rawValue).log in Settings → Diagnostics for details.") }
        let file = root.appendingPathComponent("audio.wav")
        guard FileManager.default.fileExists(atPath: file.path), let metadata = try? String(contentsOf: root.appendingPathComponent("result.json"), encoding: .utf8) else { throw AppError.message("The runtime did not return an audio result.") }
        return EngineResult(file: file, metadata: metadata)
    }
    func cancel(_ job: GenerationJob) async throws { if jobID == job.id { await stop() } }
    func terminateOwnedProcess() { if let child, child.isRunning { child.terminate() } }
    func stop() async {
        if let child, child.isRunning {
            child.terminate()
            for _ in 0..<30 { if !child.isRunning { break }; try? await Task.sleep(for: .milliseconds(100)) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child = nil; jobID = nil; try? logHandle?.close(); logHandle = nil
    }
    func download(_ result: EngineResult, to destination: URL) async throws {
        guard result.file.isFileURL else { throw AppError.message("Invalid runtime output.") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: result.file, to: destination)
        if let root = jobRoot { try? FileManager.default.removeItem(at: root) }
        jobRoot = nil
    }
}
