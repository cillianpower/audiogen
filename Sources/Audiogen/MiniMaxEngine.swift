import Foundation
import Security

struct MiniMaxManifest: Codable, Sendable {
    struct Preset: Codable, Sendable, Identifiable, Equatable {
        let id: String
        let name: String
        let minimumMemoryGB: Int
        let steps: Int
        let models: [EngineManifest.Artifact]
        var bytes: Int64 { models.reduce(0) { $0 + $1.bytes } }
    }
    let engine: String
    let version: String
    let sourceRevision: String
    let ggmlRevision: String
    let modelRevision: String
    let presets: [Preset]
    var availablePresets: [Preset] { presets.filter { UInt64($0.minimumMemoryGB) * 1_073_741_824 <= ProcessInfo.processInfo.physicalMemory } }
    static func bundled() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "minimax", withExtension: "json")!))
    }
}

@MainActor final class MiniMaxEngine: GenerationEngine {
    struct Runtime: Codable, Equatable { let sourceRevision: String; let ggmlRevision: String; let sha256: String }
    let capabilities = EngineCapabilities(textToAudio: true, referenceAudio: false, continuation: false, repaint: false, lyrics: false, instrumental: true, stems: false)
    let paths: AppPaths
    let manifest: MiniMaxManifest
    var presetID = "efficient"
    var preset: MiniMaxManifest.Preset { manifest.presets.first { $0.id == presetID } ?? manifest.presets[0] }
    var directory: URL { paths.support.appendingPathComponent("Engines/MiniMax") }
    var models: URL { directory.appendingPathComponent("models") }
    var binary: URL { directory.appendingPathComponent("runtime/mm-server") }
    var version: String { manifest.version }
    var onExit: (@MainActor () -> Void)?
    private var child: Process?
    private var logHandle: FileHandle?
    var ownsServer: Bool { child?.isRunning == true }
    private let session: URLSession
    private let base = URL(string: "http://127.0.0.1:8086")!
    private var runtimeBundle: URL { Bundle.module.resourceURL!.appendingPathComponent("MiniMaxRuntime") }
    var installed: Bool { isInstalled(preset) }
    func isInstalled(_ preset: MiniMaxManifest.Preset) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              let marker = try? JSONDecoder().decode(MiniMaxManifest.Preset.self, from: Data(contentsOf: directory.appendingPathComponent("\(preset.id).json"))),
              marker == preset,
              let runtime = try? JSONDecoder().decode(Runtime.self, from: Data(contentsOf: directory.appendingPathComponent("runtime/runtime.json"))),
              runtime.sourceRevision == manifest.sourceRevision, runtime.ggmlRevision == manifest.ggmlRevision else { return false }
        return preset.models.allSatisfy { FileManager.default.fileExists(atPath: models.appendingPathComponent($0.name).path) }
    }
    init(paths: AppPaths, manifest: MiniMaxManifest, session: URLSession? = nil) {
        self.paths = paths; self.manifest = manifest
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 300
        self.session = session ?? URLSession(configuration: config)
    }
    func install(progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        try await install(presetID: presetID, progress: progress)
    }
    func install(presetID: String, progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        guard let chosen = manifest.presets.first(where: { $0.id == presetID }) else { throw AppError.message("Unknown MiniMax preset.") }
        try paths.prepare()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let missing = chosen.models.filter { !FileManager.default.fileExists(atPath: models.appendingPathComponent($0.name).path) }.reduce(Int64(0)) { $0 + $1.bytes }
        if let available, available < missing + 1_000_000_000 { throw AppError.message("Free up \(ByteCountFormatter.string(fromByteCount: missing + 1_000_000_000, countStyle: .file)) to install MiniMax.") }
        try await installRuntime(progress: progress)
        let downloads = directory.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for artifact in chosen.models {
            try Task.checkCancellation()
            try await ArtifactDownloader().fetch(artifact, to: models.appendingPathComponent(artifact.name), downloads: downloads) { status, fraction in
                progress(status, fraction.map { (Double(completed) + $0 * Double(artifact.bytes)) / Double(chosen.bytes) })
            }
            completed += artifact.bytes
        }
        try JSONEncoder().encode(chosen).write(to: directory.appendingPathComponent("\(chosen.id).json"), options: .atomic)
    }
    func installRuntime(progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        try paths.prepare()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress("Preparing…", nil)
        let runtime = try JSONDecoder().decode(Runtime.self, from: Data(contentsOf: runtimeBundle.appendingPathComponent("runtime.json")))
        // The binary ships inside the signed app, so check its code signature rather than exact bytes:
        // release signing (including Xcode's notarisation export) re-signs it and changes its hash.
        guard runtime.sourceRevision == manifest.sourceRevision, runtime.ggmlRevision == manifest.ggmlRevision,
              CodeSignature.isValid(runtimeBundle.appendingPathComponent("mm-server")) else { throw AppError.message("The bundled MiniMax runtime failed verification. Reinstall Audiogen.") }
        let target = directory.appendingPathComponent("runtime")
        let existing = try? JSONDecoder().decode(Runtime.self, from: Data(contentsOf: target.appendingPathComponent("runtime.json")))
        if existing != runtime || !FileManager.default.isExecutableFile(atPath: binary.path) {
            guard !ownsServer else { throw AppError.message("Stop MiniMax before replacing its runtime. Model downloads can continue while it generates.") }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: runtimeBundle, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
    }
    func health() async -> Bool {
        do {
            let health = try await call("health")
            let props = try await call("props")
            guard health["status"] as? String == "ok", let version = props["version"] as? String, version.hasPrefix(String(manifest.sourceRevision.prefix(7))),
                  let inventory = props["models"] as? [String: [String]] else { return false }
            let buckets = ["lm", "depth", "cond", "dit", "vae"]
            return zip(buckets, preset.models).allSatisfy { inventory[$0.0]?.contains($0.1.name) == true }
        } catch { return false }
    }
    func start() async throws {
        if await health() { return }
        guard installed else { throw AppError.message("Download the selected MiniMax model in Settings before generating audio.") }
        guard ProcessInfo.processInfo.physicalMemory >= UInt64(preset.minimumMemoryGB) * 1_073_741_824 else { throw AppError.message("This model requires \(preset.minimumMemoryGB) GB unified memory.") }
        if (try? await call("health")) != nil {
            if ownsServer { await stop() }
            else { throw AppError.message("Port 8086 is occupied by an incompatible server. Close that server before starting MiniMax.") }
        }
        let process = Process(); process.executableURL = binary
        process.arguments = ["--models", models.path, "--host", "127.0.0.1", "--port", "8086", "--max-batch", "1"]
        process.currentDirectoryURL = directory
        let log = paths.logs.appendingPathComponent("minimax.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
        process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.onExit?() } }
        try process.run(); child = process; logHandle = handle
        do {
            for _ in 0..<60 {
                try Task.checkCancellation()
                guard process.isRunning else { throw AppError.message("MiniMax stopped unexpectedly. Open technical details and restart the engine.") }
                if await health() { return }
                try await Task.sleep(for: .seconds(1))
            }
            throw AppError.message("MiniMax took too long to become ready. Try Restart Engine.")
        } catch { await stop(); throw error }
    }
    func stop() async {
        guard let child else { return }; child.terminationHandler = nil
        if child.isRunning {
            child.terminate()
            for _ in 0..<50 { if !child.isRunning { break }; try? await Task.sleep(for: .milliseconds(100)) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        self.child = nil; try? logHandle?.close(); logHandle = nil
    }
    func terminateOwnedProcess() { child?.terminationHandler = nil; if let child, child.isRunning { child.terminate() } }
    static func payload(_ request: GenerationRequest, preset: MiniMaxManifest.Preset) throws -> [String: Any] {
        guard request.mode == .generate, request.reference == nil else { throw AppError.message("MiniMax currently supports text generation. Use ACE-Step for reference audio and repainting.") }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (10...300).contains(request.duration), (2...100).contains(request.steps) else { throw AppError.message("Enter a prompt, a duration from 10 to 300 seconds and at least two steps.") }
        var caption = request.prompt
        if request.instrumental || request.noVocals { caption += "\nInstrumental only. No singing, speech or vocals." }
        if request.noPercussion { caption += "\nNo drums, percussion, beat or rhythmic pulse." }
        if !request.avoid.isEmpty { caption += "\nExclude: \(request.avoid)." }
        // Upstream requires a nonempty lyrics field. Structural tags provide an
        // instrumental condition without inventing lyrics or changing the editor.
        var body: [String: Any] = ["caption": caption, "lyrics": request.instrumental || request.noVocals ? "[instrumental]" : "[intro]\n[verse]\n[outro]", "duration": request.duration,
            "steps": request.steps, "seed": request.seed, "lm_seed": request.seed,
            "lm_batch_size": 1, "synth_batch_size": 1, "output_format": "wav24"]
        for (key, file) in zip(["lm_model", "depth_model", "cond_model", "dit_model", "vae_model"], preset.models) { body[key] = file.name }
        return body
    }
    func generate(_ request: GenerationRequest) async throws -> GenerationJob {
        guard let chosen = manifest.presets.first(where: { $0.id == request.model }) else { throw AppError.message("Unknown MiniMax preset.") }
        if !isInstalled(chosen) {
            guard !ownsServer, await health(), chosen.id == presetID else { throw AppError.message("The requested MiniMax preset is not installed.") }
        }
        let response = try await call("synth", body: Self.payload(request, preset: chosen))
        guard let id = response["id"] as? String else { throw AppError.message("MiniMax returned an invalid job response.") }
        return GenerationJob(id: id)
    }
    func result(_ job: GenerationJob) async throws -> EngineResult? {
        let status = try await call("job", query: ["id": job.id])["status"] as? String
        switch status {
        case "running": return nil
        case "cancelled": throw CancellationError()
        case "failed": throw AppError.message("MiniMax could not generate this audio. Try Efficient or a shorter duration. Technical details are in the engine log.")
        case "done":
            let (data, response) = try await session.data(from: url("job", query: ["id": job.id, "result": "1"]))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let type = http.value(forHTTPHeaderField: "Content-Type") else { throw AppError.message("MiniMax could not return this audio.") }
            let parsed = try Self.decodeResult(data, contentType: type)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try parsed.audio.write(to: file)
            return EngineResult(file: file, metadata: parsed.metadata)
        default: throw AppError.message("MiniMax returned an unknown job status.")
        }
    }
    static func decodeResult(_ data: Data, contentType: String) throws -> (audio: Data, metadata: String) {
        guard contentType.lowercased().hasPrefix("multipart/mixed"), let boundary = contentType.components(separatedBy: "boundary=").last, boundary.count < 200, !boundary.isEmpty else { throw AppError.message("MiniMax returned an invalid audio container.") }
        let marker = Data(("--" + boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))).utf8)
        let separator = Data("\r\n\r\n".utf8)
        var offset = data.startIndex; var audio: Data?; var metadata: String?
        while let start = data.range(of: marker, in: offset..<data.endIndex) {
            let bodyStart = start.upperBound
            guard let next = data.range(of: marker, in: bodyStart..<data.endIndex) else { break }
            guard let headers = data.range(of: separator, in: bodyStart..<next.lowerBound), next.lowerBound >= headers.upperBound + 2 else { throw AppError.message("MiniMax returned a truncated audio container.") }
            let header = String(decoding: data[bodyStart..<headers.lowerBound], as: UTF8.self).lowercased()
            let body = Data(data[headers.upperBound..<(next.lowerBound - 2)])
            if header.contains("application/json") { metadata = String(decoding: body, as: UTF8.self) }
            if header.contains("audio/wav") { audio = body }
            offset = next.lowerBound
        }
        guard let audio, audio.starts(with: Data("RIFF".utf8)), let metadata, (try? JSONSerialization.jsonObject(with: Data(metadata.utf8))) != nil else { throw AppError.message("MiniMax returned an invalid WAV result.") }
        return (audio, metadata)
    }
    func cancel(_ job: GenerationJob) async throws { _ = try await call("job", query: ["id": job.id, "cancel": "1"], body: [:]) }
    func download(_ result: EngineResult, to destination: URL) async throws {
        guard result.file.isFileURL else { throw AppError.message("Invalid MiniMax audio location.") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: result.file, to: destination)
    }
    private func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
    private func call(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url(path, query: query))
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError.message("MiniMax could not complete this request. Open technical details for the engine log.") }
        return json
    }
}

enum CodeSignature {
    /// True when the file has an intact code signature, Developer ID or ad hoc. Any change to a signed
    /// binary invalidates it, and unsigned files fail.
    static func isValid(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }
}
