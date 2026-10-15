import Foundation

@MainActor final class ACEEngine: GenerationEngine {
    let capabilities = EngineCapabilities(textToAudio: true, referenceAudio: true, continuation: false, repaint: true, lyrics: false, instrumental: true, stems: false)
    var installed: Bool { installer.modelInstalled(modelID) }
    var directory: URL { installer.paths.engine }
    var version: String { installer.manifest.version }
    var modelID = ACEModel.turbo.rawValue
    let installer: RuntimeInstaller
    private let base = URL(string: "http://127.0.0.1:8001")!
    private var child: Process?
    private var logHandle: FileHandle?
    private let session: URLSession
    var ownsServer: Bool { child?.isRunning == true }
    private(set) var jobProgress: Double?
    var onExit: (@MainActor () -> Void)?
    init(paths: AppPaths, manifest: EngineManifest, session: URLSession? = nil) {
        installer = RuntimeInstaller(paths: paths, manifest: manifest)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        self.session = session ?? URLSession(configuration: config)
    }
    func install(progress: @escaping @MainActor (String, Double?) -> Void) async throws { try await installer.install(progress: progress) }
    func health() async -> Bool {
        do {
            let data = try await call("health")
            guard let health = data as? [String: Any], health["service"] as? String == "ACE-Step API", health["status"] as? String == "ok" else { return false }
            let inventory = try await call("v1/models") as? [String: Any]
            let models = inventory?["models"] as? [[String: Any]] ?? []
            // LoRA endpoints operate on the primary handler, so reuse only a
            // server whose selected checkpoint is primary when inventory says so.
            if let primary = inventory?["default_model"] as? String, primary != modelID { return false }
            return health["models_initialized"] as? Bool == true && models.contains {
                $0["name"] as? String == modelID && ($0["is_loaded"] as? Bool != false)
            }
        } catch { return false }
    }
    func start() async throws {
        if await health() { return }
        guard installed else { throw AppError.message("Install ACE-Step before generating audio.") }
        guard ProcessInfo.processInfo.physicalMemory >= UInt64(ACEModel(rawValue: modelID)?.minimumMemoryGB ?? 16) * 1_073_741_824 else { throw AppError.message("This model requires more unified memory. Choose a smaller model.") }
        // Never terminate or replace a process that we do not own.
        if (try? await call("health")) != nil { throw AppError.message("Another server is using port 8001, but the selected model is not ready. Configure that server or close it before restarting this engine.") }
        if child?.isRunning == true { await stop() }
        let process = Process()
        process.executableURL = installer.python
        process.arguments = ["-m", "acestep.api_server", "--host", "127.0.0.1", "--port", "8001"]
        process.currentDirectoryURL = installer.paths.repository
        var env = installer.environment
        for key in env.keys.filter({ $0.hasPrefix("ACESTEP_") }) { env.removeValue(forKey: key) }
        env["ACESTEP_PROJECT_ROOT"] = installer.paths.repository.path
        env["ACESTEP_CHECKPOINTS_DIR"] = installer.paths.models.path
        env["ACESTEP_API_HOST"] = "127.0.0.1"
        env["ACESTEP_CONFIG_PATH"] = modelID
        env["ACESTEP_LM_BACKEND"] = "mlx"
        env["ACESTEP_INIT_LLM"] = "false"
        env["ACESTEP_NO_INIT"] = "false"
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        let log = installer.paths.logs.appendingPathComponent("ace-step.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.onExit?() } }
        try process.run()
        child = process; logHandle = handle
        do {
            for _ in 0..<300 {
                try Task.checkCancellation()
                guard process.isRunning else { throw AppError.message("ACE-Step stopped unexpectedly. Open technical details, then restart the engine.") }
                if await health() { return }
                try await Task.sleep(for: .seconds(2))
            }
            throw AppError.message("ACE-Step took too long to become ready. Open technical details and try Restart Engine.")
        } catch { await stop(); throw error }
    }
    func stop() async {
        guard let process = child else { return }
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            for _ in 0..<30 {
                if !process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        child = nil
        try? logHandle?.close(); logHandle = nil
    }
    // Used synchronously by the application termination delegate.
    func terminateOwnedProcess() { child?.terminationHandler = nil; if let child, child.isRunning { child.terminate() } }
    static func payload(_ request: GenerationRequest) throws -> [String: Any] {
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (10...600).contains(request.duration) else { throw AppError.message("Enter a prompt and choose a duration between 10 and 600 seconds.") }
        var clauses: [String] = []
        if request.instrumental || request.noVocals { clauses.append("Instrumental audio, without vocals.") }
        if request.noPercussion { clauses.append("No drums, percussion, beat or rhythmic pulse.") }
        if !request.avoid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clauses.append("Exclude: " + request.avoid + ".") }
        // Turbo's direct DiT workflow has no negative CFG input. Constraints become
        // backend-only caption conditioning; the user's visible prompt stays intact.
        var fields: [String: Any] = [
            "prompt": ([request.prompt] + clauses).joined(separator: "\n"),
            "lyrics": request.instrumental || request.noVocals ? "[Instrumental]" : "",
            "audio_duration": request.duration, "seed": request.seed, "use_random_seed": false,
            "batch_size": 1, "audio_format": "wav", "model": request.model,
            "inference_steps": request.steps, "thinking": false, "use_format": false,
            "use_cot_caption": false, "use_cot_language": false, "lm_backend": "mlx",
            "task_type": "text2music", "audio_cover_strength": request.referenceStrength
        ]
        if let reference = request.reference { fields["reference_audio_path"] = reference.path }
        if request.mode == .repaint {
            guard let source = request.source, let region = request.region, region.start >= 0, region.end > region.start else { throw AppError.message("Select a region of source audio to repaint.") }
            fields["src_audio_path"] = source.path
            fields["task_type"] = "repaint"
            fields["repainting_start"] = region.start
            fields["repainting_end"] = region.end
            fields["chunk_mask_mode"] = "explicit"
        }
        return fields
    }
    func configureLoRA(_ request: GenerationRequest) async throws {
        _ = try await call("v1/lora/unload", body: [:])
        if let url = request.lora {
            guard FileManager.default.fileExists(atPath: url.path) else { throw AppError.message("The saved LoRA could not be found. Choose it again in the Model inspector.") }
            _ = try await call("v1/lora/load", body: ["lora_path": url.path])
            _ = try await call("v1/lora/scale", body: ["scale": request.loraScale ?? 1])
        }
    }
    func generate(_ request: GenerationRequest) async throws -> GenerationJob {
        var fields = try Self.payload(request)
        var files: [(field: String, url: URL)] = []
        if let reference = request.reference { fields.removeValue(forKey: "reference_audio_path"); files.append(("reference_audio", reference)) }
        if request.mode == .repaint, let source = request.source { fields.removeValue(forKey: "src_audio_path"); files.append(("src_audio", source)) }
        let response: Any
        if files.isEmpty { response = try await call("release_task", body: fields) }
        else {
            let stringFields = fields.mapValues { value in
                if let value = value as? Bool { return value ? "true" : "false" }
                return String(describing: value)
            }
            let multipart = try await MultipartBuilder().build(fields: stringFields, files: files)
            defer { try? FileManager.default.removeItem(at: multipart.url) }
            response = try await call("release_task", multipart: multipart)
        }
        guard let data = response as? [String: Any], let id = data["task_id"] as? String else { throw AppError.message("ACE-Step returned an unexpected job response.") }
        return GenerationJob(id: id)
    }
    func result(_ job: GenerationJob) async throws -> EngineResult? {
        guard let rows = try await call("query_result", body: ["task_id_list": [job.id]]) as? [[String: Any]], let row = rows.first else { throw AppError.message("ACE-Step could not find this generation.") }
        jobProgress = row["status"] as? Int == 0 ? Self.progress(row) : nil
        if row["status"] as? Int == 2 { throw AppError.message("ACE-Step could not generate this audio. Try a shorter duration, or restart the engine. Technical details are in the engine log.") }
        guard row["status"] as? Int == 1 else { return nil }
        guard let encoded = row["result"] as? String, let bytes = encoded.data(using: .utf8), let outputs = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]], let path = outputs.first?["file"] as? String,
              let url = URL(string: path, relativeTo: base)?.absoluteURL, url.scheme == "http", url.host == "127.0.0.1", url.port == 8001, url.path == "/v1/audio" else { throw AppError.message("ACE-Step returned an invalid audio result.") }
        return EngineResult(file: url, metadata: encoded)
    }
    /// A running task's result holds `[{"progress": 0...1, "stage": ...}]`.
    static func progress(_ row: [String: Any]) -> Double? {
        guard let encoded = row["result"] as? String, let bytes = encoded.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
              let value = (items.first?["progress"] as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
        return min(1, value)
    }
    func cancel(_ job: GenerationJob) async throws {
        // Upstream has no cancellation endpoint. Only an owned worker can be stopped.
        if ownsServer { await stop() }
        else { throw AppError.message("Stopped waiting for this result. The shared ACE-Step server may continue rendering it because its API does not support cancellation.") }
    }
    func download(_ result: EngineResult, to destination: URL) async throws {
        let (file, response) = try await session.download(from: result.file)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppError.message("The generated audio could not be downloaded.") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: destination)
    }
    private func call(_ path: String, body: [String: Any]? = nil, multipart: MultipartAudio? = nil) async throws -> Any {
        var request = URLRequest(url: base.appendingPathComponent(path))
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let response: URLResponse
        if let multipart {
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
            (data, response) = try await session.upload(for: request, fromFile: multipart.url)
        } else { (data, response) = try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = "\(Date()) \(path): \(String(decoding: data, as: UTF8.self))\n"
            let log = installer.paths.logs.appendingPathComponent("api-errors.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: log) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(detail.utf8)); try? handle.close() }
            throw AppError.message("ACE-Step could not complete this request. Check technical details for the API error.")
        }
        guard let wrapper = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError.message("ACE-Step returned an unexpected response. Check the engine version and log.") }
        // The pinned runtime returns an OpenAI-compatible inventory, while earlier
        // releases and the published client documentation use a wrapped inventory.
        if path == "v1/models", wrapper["object"] as? String == "list", let rows = wrapper["data"] as? [[String: Any]] {
            return ["models": rows.compactMap { row -> [String: Any]? in
                guard let id = row["id"] as? String, let name = id.split(separator: "/").last else { return nil }
                var model = row
                model["name"] = String(name)
                return model
            }]
        }
        guard wrapper["code"] as? Int == 200, let result = wrapper["data"] else { throw AppError.message("ACE-Step returned an unexpected response. Check the engine version and log.") }
        return result
    }
}
