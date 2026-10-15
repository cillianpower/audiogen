import Foundation
import Observation

enum AudioWorkspace: String, CaseIterable, Identifiable {
    case generate = "Generate", extract = "Extract", transform = "Transform"
    var id: Self { self }
    var runtime: EngineID? { self == .extract ? .sam : self == .transform ? .after : nil }
}
struct ExtractionAnchor: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var present: Bool
    var region: AudioRegion
}
struct ProcessingRequest: Codable, Sendable {
    let engine: EngineID
    let model: String
    let source: URL
    var reference: URL?
    var description = ""
    var anchors: [ExtractionAnchor] = []
    var steps = 16
    var seed: Int64 = 42
    var guidance = 1.0
    var duration: Double
    /// Processes each channel of a stereo source separately; nil in older records means mono.
    var stereo: Bool?
    func validate() throws {
        guard engine == .sam || engine == .after, duration.isFinite, duration > 0, seed >= 0,
              (1...64).contains(steps), FileManager.default.fileExists(atPath: source.path) else { throw AppError.message("Choose valid source audio and processing settings.") }
        if engine == .sam {
            guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("Describe the sound to extract.") }
            guard anchors.count <= 3 else { throw AppError.message("SAM supports up to three sound examples.") }
            guard anchors.isEmpty || duration <= 30 else { throw AppError.message("Sound examples are supported for clips up to 30 seconds. Remove examples to process this longer clip.") }
            for anchor in anchors {
                guard anchor.region.start.isFinite, anchor.region.end.isFinite, anchor.region.start >= 0,
                      anchor.region.end > anchor.region.start, anchor.region.end <= duration else { throw AppError.message("Choose sound examples within the source audio.") }
            }
        } else {
            guard let reference, FileManager.default.fileExists(atPath: reference.path), guidance.isFinite, (0...3).contains(guidance) else { throw AppError.message("Choose a timbre reference and valid structure guidance.") }
        }
    }
}
enum ProcessingState: String, Codable { case waiting, processing, ready, failed, cancelled }
enum AudioOutputRole: String, Codable, Identifiable, Sendable {
    case extracted = "Extracted sound", remaining = "Remaining audio", transformed = "Transformed audio"
    var id: Self { self }
}
struct ProcessingOutput: Codable, Identifiable, Sendable {
    let role: AudioOutputRole
    var file: URL
    var duration: Double?
    var id: AudioOutputRole { role }
}
struct ProcessingRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var created = Date()
    var name: String
    let request: ProcessingRequest
    let sourceRevision: String
    var state: ProcessingState = .waiting
    var outputs: [ProcessingOutput] = []
    var metadata: String?
    var error: String?
}
struct ProcessingWorkerResult: Codable, Sendable {
    struct Output: Codable, Sendable { let role: AudioOutputRole; let filename: String }
    let outputs: [Output]
    let details: [String: String]
}
struct ProcessingCatalog: Codable {
    let runtimes: [PythonRuntimeSpec]
    static func bundled() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: RuntimeCatalog.resourceRoot.appendingPathComponent("processing.json")))
    }
}

/// A lease covers inference and output finalization across all three workspaces.
@MainActor @Observable final class AudioWorkScheduler {
    private(set) var owner: UUID?
    private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []
    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if owner == nil { owner = id; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiting.append((id, continuation)) }
        } onCancel: { Task { @MainActor in self.cancelWaiting(id) } }
        do { try Task.checkCancellation() } catch { release(id); throw error }
    }
    private func cancelWaiting(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) { waiting.remove(at: index).1.resume(throwing: CancellationError()) }
    }
    func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        if !waiting.isEmpty { let next = waiting.removeFirst(); owner = next.0; next.1.resume() }
    }
}

actor ProcessingPersistence {
    let directory: URL
    init(paths: AppPaths) { directory = paths.support.appendingPathComponent("Processing") }
    func load() throws -> [ProcessingRecord] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                var item = try JSONDecoder().decode(ProcessingRecord.self, from: Data(contentsOf: url))
                if item.state == .processing || item.state == .waiting { item.state = .cancelled; item.error = "Interrupted when Audiogen closed."; try save(item) }
                return item
            }.sorted { $0.created > $1.created }
    }
    func save(_ item: ProcessingRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(item).write(to: directory.appendingPathComponent(item.id.uuidString + ".json"), options: .atomic)
    }
    func remove(_ item: ProcessingRecord) throws { try FileManager.default.removeItem(at: directory.appendingPathComponent(item.id.uuidString + ".json")) }
}
