import Foundation
import CryptoKit

@MainActor final class ProcessRunner {
    private var process: Process?
    func run(_ executable: URL, _ arguments: [String], directory: URL, environment: [String: String], log: URL) async throws {
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.environment = environment
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        child.standardOutput = handle
        child.standardError = handle
        child.standardInput = FileHandle.nullDevice
        process = child
        defer { process = nil; try? handle.close() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                child.terminationHandler = { process in
                    if process.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: AppError.message("Engine preparation failed. Open technical details for the installation log.")) }
                }
                do { try Task.checkCancellation(); try child.run() }
                catch { child.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        } onCancel: { Task { @MainActor in if child.isRunning { child.terminate() } } }
        try Task.checkCancellation()
    }
}

private final class DownloadProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate: Double = 0
    func permits(_ fraction: Double) -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastUpdate >= 0.1 || fraction >= 1 else { return false }
            lastUpdate = now
            return true
        }
    }
}

@MainActor final class DownloadTransfer: NSObject, URLSessionDownloadDelegate {
    private nonisolated let progressGate = DownloadProgressGate()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var download: URLSessionDownloadTask?
    private var resumeFile: URL?
    private var progress: (@MainActor (Double, Int64, Int64) -> Void)?
    private var lastActivity = Date()
    private var stalled = false
    private var watchdog: Task<Void, Never>?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86_400
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    func fetch(_ url: URL, resumeFile: URL, progress: @escaping @MainActor (Double, Int64, Int64) -> Void) async throws -> URL {
        self.resumeFile = resumeFile
        self.progress = progress
        lastActivity = Date()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(lastActivity) > 90 { stalled = true; download?.cancel(); return }
            }
        }
        defer { watchdog?.cancel(); self.progress = nil; download = nil; session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if let data = try? Data(contentsOf: resumeFile) { download = session.downloadTask(withResumeData: data) }
                else { download = session.downloadTask(with: url) }
                download?.resume()
            }
        } onCancel: { Task { @MainActor in self.download?.cancel() } }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        guard progressGate.permits(fraction) else { return }
        Task { @MainActor in self.lastActivity = Date(); self.progress?(fraction, totalBytesWritten, totalBytesExpectedToWrite) }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary URL is only valid during this delegate callback.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw AppError.message("The download server could not provide this file. Try Resume.") }
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in
                if let file = self.resumeFile { try? FileManager.default.removeItem(at: file) }
                self.continuation?.resume(returning: destination); self.continuation = nil
            }
        } catch { Task { @MainActor in self.continuation?.resume(throwing: error); self.continuation = nil } }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            if let resume, let file = self.resumeFile { try? resume.write(to: file, options: .atomic) }
            self.continuation?.resume(throwing: self.stalled ? AppError.message("The download stopped receiving data. Choose Resume to retry; partial data has been kept.") : error); self.continuation = nil
        }
    }
}

actor FileVerifier {
    func matches(_ url: URL, sha256: String, progress: (@Sendable (Int64) -> Void)? = nil) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(); var read: Int64 = 0; var lastReport = Date.distantPast
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { try Task.checkCancellation(); hash.update(data: chunk); read += Int64(chunk.count)
            if Date().timeIntervalSince(lastReport) > 0.25 { progress?(read); lastReport = Date() }
        }
        progress?(read)
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == sha256.lowercased()
    }
}

@MainActor final class RuntimeInstaller {
    let paths: AppPaths
    let manifest: EngineManifest
    let runner = ProcessRunner()
    let verifier = FileVerifier()
    init(paths: AppPaths, manifest: EngineManifest) { self.paths = paths; self.manifest = manifest }
    var marker: URL { paths.engine.appendingPathComponent("installed.json") }
    var runtimeMarker: URL { paths.engine.appendingPathComponent("runtime-installed.json") }
    var runtimeInstalled: Bool {
        ((try? JSONDecoder().decode(EngineManifest.self, from: Data(contentsOf: runtimeMarker))) == manifest || (try? JSONDecoder().decode(EngineManifest.self, from: Data(contentsOf: marker))) == manifest) && FileManager.default.isExecutableFile(atPath: python.path)
    }
    var commonModels: [EngineManifest.Artifact] { manifest.models.filter { !$0.name.hasPrefix("acestep-v15-turbo/") } }
    var installed: Bool { modelInstalled("acestep-v15-turbo") }
    func modelInstalled(_ id: String) -> Bool {
        guard runtimeInstalled, commonModels.allSatisfy({ artifact in
            (try? FileManager.default.attributesOfItem(atPath: paths.models.appendingPathComponent(artifact.name).path)[.size] as? Int64) == artifact.bytes
        }) else { return false }
        let root = paths.models.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".audiogen-imported").path) { return ACECheckpointImporter.complete(root) }
        let files = id == "acestep-v15-turbo" ? manifest.models.filter { $0.name.hasPrefix(id + "/") } : (try? RuntimeCatalog.bundled())?.aceModels.first { $0.id == id }?.files ?? []
        return !files.isEmpty && files.allSatisfy { artifact in
            (try? FileManager.default.attributesOfItem(atPath: paths.models.appendingPathComponent(artifact.name).path)[.size] as? Int64) == artifact.bytes
        }
    }
    var python: URL { paths.repository.appendingPathComponent(".venv/bin/python") }
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        env["UV_PYTHON_INSTALL_DIR"] = paths.runtime.appendingPathComponent("python").path
        env["UV_CACHE_DIR"] = paths.runtime.appendingPathComponent("cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_NO_PROGRESS"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["DO_NOT_TRACK"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        return env
    }
    func installRuntime(progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        if runtimeInstalled { return }
        try await install(progress: progress, includeModels: false)
    }
    func install(progress: @escaping @MainActor (String, Double?) -> Void, includeModels: Bool = true) async throws {
        try paths.prepare()
        let available = try paths.engine.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let modelBytes = includeModels ? manifest.models.reduce(Int64(0)) { $0 + $1.bytes } : 0
        let existingModelBytes = Self.directoryBytes(paths.models)
        let required = max(0, modelBytes - existingModelBytes) + 6_000_000_000
        if let available, available < required { throw AppError.message("There is not enough free disk space to install this engine. Free up approximately \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) and try again.") }
        let downloads = paths.runtime.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        for artifact in [manifest.runtime, manifest.python, manifest.repository] {
            try Task.checkCancellation()
            let archive = downloads.appendingPathComponent(artifact.name)
            try await ArtifactDownloader().fetch(artifact, to: archive, downloads: downloads, progress: progress)
        }
        let log = paths.logs.appendingPathComponent("installation.log")
        progress("Preparing…", nil)
        let uv = paths.runtime.appendingPathComponent("uv-aarch64-apple-darwin/uv")
        if !FileManager.default.fileExists(atPath: uv.path) {
            try await runner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", downloads.appendingPathComponent(manifest.runtime.name).path, "-C", paths.runtime.path], directory: paths.runtime, environment: environment, log: log)
        }
        let standalonePython = paths.runtime.appendingPathComponent("python/bin/python3")
        if !FileManager.default.fileExists(atPath: standalonePython.path) {
            try await runner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", downloads.appendingPathComponent(manifest.python.name).path, "-C", paths.runtime.path], directory: paths.runtime, environment: environment, log: log)
        }
        if !FileManager.default.fileExists(atPath: paths.repository.appendingPathComponent("uv.lock").path) {
            try await runner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", downloads.appendingPathComponent(manifest.repository.name).path, "-C", paths.engine.path], directory: paths.engine, environment: environment, log: log)
            try FileManager.default.moveItem(at: paths.engine.appendingPathComponent(manifest.repositoryDirectory), to: paths.repository)
        }
        progress("Installing runtime dependencies · see installation.log", nil)
        try await runner.run(uv, ["sync", "--frozen", "--python", standalonePython.path, "--no-python-downloads", "--no-dev", "--no-editable"], directory: paths.repository, environment: environment, log: log)
        progress("Preparing…", nil)
        try FileManager.default.createDirectory(at: paths.models, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: runtimeMarker, options: .atomic)
        var completedBytes: Int64 = 0
        for artifact in includeModels ? manifest.models : [] {
            try Task.checkCancellation()
            try await ArtifactDownloader().fetch(artifact, to: paths.models.appendingPathComponent(artifact.name), downloads: downloads) { label, fraction in
                progress(label, fraction.map { (Double(completedBytes) + $0 * Double(artifact.bytes)) / Double(modelBytes) })
            }
            completedBytes += artifact.bytes
        }
        let checkpoints = paths.repository.appendingPathComponent("checkpoints")
        if !FileManager.default.fileExists(atPath: checkpoints.path) { try FileManager.default.createSymbolicLink(at: checkpoints, withDestinationURL: paths.models) }
        if includeModels { try JSONEncoder().encode(manifest).write(to: marker, options: .atomic) }
    }
    nonisolated private static func directoryBytes(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}

@MainActor final class ArtifactDownloader {
    let verifier = FileVerifier()
    func fetch(_ artifact: EngineManifest.Artifact, to destination: URL, downloads: URL, progress: @escaping @MainActor (String, Double?) -> Void) async throws {
        guard artifact.sha256.count == 64, artifact.url.scheme == "https", !artifact.name.split(separator: "/").contains("..") else { throw AppError.message("Invalid engine manifest.") }
        let label = URL(fileURLWithPath: artifact.name).lastPathComponent
        let total = ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file)
        func verify(_ url: URL) async throws -> Bool {
            progress("Verifying \(label)", 0.95)
            return try await verifier.matches(url, sha256: artifact.sha256) { bytes in
                Task { @MainActor in progress("Verifying \(label)", 0.95 + 0.05 * Double(bytes) / Double(max(1, artifact.bytes))) }
            }
        }
        if FileManager.default.fileExists(atPath: destination.path), try await verify(destination) { progress("Verified \(label)", 1); return }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = downloads.appendingPathComponent(artifact.sha256 + ".download")
        if !FileManager.default.fileExists(atPath: staged.path) {
            progress("Downloading \(label) · \(total)", 0)
            let transfer = DownloadTransfer()
            var lastBytes: Int64 = 0; var lastDate = Date()
            let resumeFile = downloads.appendingPathComponent(artifact.sha256 + ".resume")
            let hadResumeData = FileManager.default.fileExists(atPath: resumeFile.path)
            var receivedBytes = false
            let report: @MainActor (Double, Int64, Int64) -> Void = { fraction, bytes, expected in
                receivedBytes = true
                let now = Date(); let elapsed = max(0.1, now.timeIntervalSince(lastDate))
                let speed = ByteCountFormatter.string(fromByteCount: Int64(Double(max(0, bytes - lastBytes)) / elapsed), countStyle: .file)
                let done = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                let value = expected > 0 ? fraction : Double(bytes) / Double(max(1, artifact.bytes))
                progress("Downloading \(label) · \(done) / \(total) · \(speed)/s", min(1, value) * 0.95)
                lastBytes = bytes; lastDate = now
            }
            let temporary: URL
            do { temporary = try await transfer.fetch(artifact.url, resumeFile: resumeFile, progress: report) }
            catch {
                // Expired signed URLs or rejected resume data should not trap
                // the user in a perpetual Resume loop. Retry the pinned URL once.
                guard hadResumeData, !receivedBytes, !Task.isCancelled else { throw error }
                try? FileManager.default.removeItem(at: resumeFile)
                progress("Restarting \(label) after expired resume data", 0)
                temporary = try await DownloadTransfer().fetch(artifact.url, resumeFile: resumeFile, progress: report)
            }
            try FileManager.default.moveItem(at: temporary, to: staged)
        }
        guard try await verify(staged) else {
            try? FileManager.default.removeItem(at: staged)
            throw AppError.message("\(label) failed verification. Choose Resume to download it again.")
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staged, to: destination)
    }
}
