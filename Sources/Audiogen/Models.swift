import Foundation

struct EngineCapabilities: Sendable {
    let textToAudio: Bool
    let referenceAudio: Bool
    let continuation: Bool
    let repaint: Bool
    let lyrics: Bool
    let instrumental: Bool
    let stems: Bool
}
enum GenerationMode: String, Codable, CaseIterable, Identifiable {
    case generate = "Generate", repaint = "Repaint"
    var id: Self { self }
}
struct AudioRegion: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
}
struct GenerationRequest: Codable, Sendable {
    var prompt = ""
    var avoid = ""
    var duration: Double = 30
    var seed: Int64 = 0
    var instrumental = true
    var noPercussion = false
    var noVocals = true
    var model = "acestep-v15-turbo"
    var steps = 8
    var lyrics: String?
    var lora: URL?
    var loraScale: Double?
    var referenceStrength = 0.5
    var mode: GenerationMode = .generate
    var reference: URL?
    var source: URL?
    var region: AudioRegion?
}
enum GenerationState: String, Codable { case waiting, generating, ready, failed, cancelled }
struct Generation: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var created = Date()
    var engine = "ACE-Step 1.5"
    var engineVersion = "v0.1.8"
    var engineID: EngineID?
    var resolvedEngineID: EngineID { engineID ?? EngineID.named(engine) }
    var request: GenerationRequest
    var state: GenerationState = .waiting
    var audio: URL?
    var actualDuration: Double?
    var taskID: String?
    var error: String?
    var backendMetadata: String?
    var starred: Bool?
    var isStarred: Bool { starred == true }
    /// Audio brought in from outside, such as a bounce from a DAW, rather than generated.
    var imported: Bool?
    var isImported: Bool { imported == true }
    var source: LibrarySource { isImported ? .imported : .engine(resolvedEngineID) }
}
enum LibrarySource: Hashable, Sendable {
    case engine(EngineID), imported
    var name: String {
        switch self {
        case .imported: "Imported"
        case .engine(.ace): "ACE-Step"
        case .engine(.miniMax): "MiniMax"
        case .engine(let id): id.name
        }
    }
}
struct GenerationJob: Sendable { let id: String }
struct EngineResult: Sendable { let file: URL; let metadata: String }
struct EngineManifest: Codable, Sendable, Equatable {
    struct Artifact: Codable, Sendable, Equatable {
        let name: String
        let url: URL
        let sha256: String
        let bytes: Int64
    }
    struct Preset: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        let minimumMemoryGB: Int
        let steps: Int
    }
    let engine: String
    let version: String
    let platform: String
    let sourceRevision: String
    let modelRevision: String
    let runtime: Artifact
    let python: Artifact
    let repository: Artifact
    let repositoryDirectory: String
    let models: [Artifact]
    let presets: [Preset]
    static func bundled() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "ace-step", withExtension: "json")!))
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}
struct AppPaths: Sendable {
    let support: URL
    let logs: URL
    var engine: URL { support.appendingPathComponent("Engines/ACE-Step", isDirectory: true) }
    var repository: URL { engine.appendingPathComponent("repository", isDirectory: true) }
    var runtime: URL { engine.appendingPathComponent("runtime", isDirectory: true) }
    var models: URL { engine.appendingPathComponent("models", isDirectory: true) }
    var metadata: URL { support.appendingPathComponent("Generations", isDirectory: true) }
    var references: URL { support.appendingPathComponent("References", isDirectory: true) }
    var config: URL { support.appendingPathComponent("Config", isDirectory: true) }
    var peaks: URL { support.appendingPathComponent("Waveforms", isDirectory: true) }
    static var standard: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(
            support: existingDirectory(home: home, path: "Library/Application Support/Audiogen", legacy: "Library/Application Support/GenerativeAudio"),
            logs: existingDirectory(home: home, path: "Library/Logs/Audiogen", legacy: "Library/Logs/GenerativeAudio")
        )
    }
    static var defaultOutput: URL {
        existingDirectory(home: FileManager.default.homeDirectoryForCurrentUser, path: "Music/Audiogen/Library", legacy: "Music/Generative Audio/Library")
    }
    // Keep existing absolute audio paths and managed Python environments valid.
    private static func existingDirectory(home: URL, path: String, legacy: String) -> URL {
        let current = home.appendingPathComponent(path)
        let previous = home.appendingPathComponent(legacy)
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: previous.path) ? previous : current
    }
    func prepare() throws {
        for url in [support, logs, engine, runtime, metadata, references, config, peaks] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
}
@MainActor protocol GenerationEngine: AnyObject {
    var capabilities: EngineCapabilities { get }
    var installed: Bool { get }
    var ownsServer: Bool { get }
    var directory: URL { get }
    var version: String { get }
    var onExit: (@MainActor () -> Void)? { get set }
    func terminateOwnedProcess()
    func download(_ result: EngineResult, to destination: URL) async throws
    func install(progress: @escaping @MainActor (String, Double?) -> Void) async throws
    func start() async throws
    func stop() async
    func health() async -> Bool
    func generate(_ request: GenerationRequest) async throws -> GenerationJob
    func result(_ job: GenerationJob) async throws -> EngineResult?
    func cancel(_ job: GenerationJob) async throws
    /// Fraction of the current job completed, when the engine reports it.
    var jobProgress: Double? { get }
}
extension GenerationEngine { var jobProgress: Double? { nil } }


enum EngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    case ace, miniMax, stableAudio, musicGen, yue, sam, after
    static let generationCases: [Self] = [.ace, .miniMax, .stableAudio, .musicGen, .yue]
    var id: Self { self }
    var name: String {
        switch self { case .ace: "ACE-Step 1.5"; case .miniMax: "MiniMax Music 3"; case .stableAudio: "Stable Audio 3"; case .musicGen: "MusicGen MLX"; case .yue: "YuE2 MLX"; case .sam: "SAM-Audio"; case .after: "AFTER" }
    }
    var isPythonRuntime: Bool { self != .ace && self != .miniMax }
    /// Stable Audio and MusicGen render any length; the others need at least 10 seconds.
    var minimumDuration: Double { self == .stableAudio || self == .musicGen ? 1 : 10 }
    var durationChoices: [Double] { [1, 2, 5, 10, 20, 30, 60, 120].filter { $0 >= minimumDuration } }
    static func named(_ name: String) -> Self { allCases.first { $0.name == name } ?? .ace }
}

enum ACEModel: String, CaseIterable, Identifiable {
    case turbo = "acestep-v15-turbo"
    case sft = "acestep-v15-sft"
    case xlTurbo = "acestep-v15-xl-turbo"
    case xlSFT = "acestep-v15-xl-sft"
    var id: String { rawValue }
    var name: String {
        switch self { case .turbo: "Turbo"; case .sft: "SFT"; case .xlTurbo: "XL Turbo"; case .xlSFT: "XL SFT" }
    }
    var steps: Int { rawValue.contains("turbo") ? 8 : 50 }
    var minimumMemoryGB: Int { rawValue.contains("xl") ? 32 : 16 }
}

struct GenerationPlan {
    static func requests(base: GenerationRequest, selected: EngineID, both: Bool, aceModel: ACEModel, miniMaxModel: String, miniMaxSteps: Int) -> [(EngineID, GenerationRequest)] {
        let targets: [EngineID] = both && (selected == .ace || selected == .miniMax) ? [selected, selected == .ace ? .miniMax : .ace] : [selected]
        return targets.map { id in
            var request = base
            request.model = id == .ace ? aceModel.rawValue : id == .miniMax ? miniMaxModel : base.model
            if id != selected { request.steps = id == .ace ? aceModel.steps : miniMaxSteps }
            if id == .miniMax { request.reference = nil; request.source = nil; request.region = nil; request.mode = .generate; request.lora = nil; request.loraScale = nil }
            return (id, request)
        }
    }
}

extension GenerationPlan {
    /// The first take keeps the chosen seed; further takes get distinct random seeds.
    static func seeds(first: Int64, takes: Int, random: () -> Int64 = { Int64.random(in: 0...Int64(Int32.max)) }) -> [Int64] {
        var seeds = [first]
        while seeds.count < max(1, takes) { let seed = random(); if !seeds.contains(seed) { seeds.append(seed) } }
        return seeds
    }
}

struct ACECheckpointImporter {
    static func complete(_ source: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "config.json" }),
              files.contains(where: { $0.pathExtension == "safetensors" }) else { return false }
        let index = source.appendingPathComponent("model.safetensors.index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            guard let data = try? Data(contentsOf: index), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weights = json["weight_map"] as? [String: String], !weights.isEmpty else { return false }
            return Set(weights.values).allSatisfy { name in
                !name.contains("/") && !name.contains("..") && FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path)
            }
        }
        return files.contains { $0.lastPathComponent == "model.safetensors" }
    }
    static func copy(_ source: URL, to destination: URL) throws {
        guard complete(source) else { throw AppError.message("The checkpoint must contain config.json and all safetensors weights. Download the complete checkpoint folder before importing it.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw AppError.message("That model already exists. Its files have been preserved.") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try Data().write(to: staging.appendingPathComponent(".audiogen-imported"))
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}
