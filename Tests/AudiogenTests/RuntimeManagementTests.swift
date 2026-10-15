import XCTest
import Foundation
@testable import Audiogen

@MainActor final class RuntimeManagementTests: XCTestCase {
    func testPartialACECheckpointDoesNotBecomeAvailableDuringDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(support: root, logs: root.appendingPathComponent("logs"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineManifest.bundled())) as? [String: Any])
        var artifacts = try XCTUnwrap(json["models"] as? [[String: Any]])
        for index in artifacts.indices { artifacts[index]["bytes"] = 1 }
        json["models"] = artifacts
        let manifest = try JSONDecoder().decode(EngineManifest.self, from: JSONSerialization.data(withJSONObject: json))
        let installer = RuntimeInstaller(paths: paths, manifest: manifest)
        try paths.prepare()
        try FileManager.default.createDirectory(at: installer.python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: installer.python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.python.path)
        try JSONEncoder().encode(manifest).write(to: installer.runtimeMarker)
        for file in installer.commonModels {
            let destination = paths.models.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: destination)
        }
        let checkpoint = paths.models.appendingPathComponent("acestep-v15-xl-sft")
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: checkpoint.appendingPathComponent("config.json"))
        try Data([0]).write(to: checkpoint.appendingPathComponent("model-00001-of-00004.safetensors"))
        XCTAssertTrue(installer.runtimeInstalled)
        XCTAssertFalse(installer.modelInstalled("acestep-v15-xl-sft"))
        XCTAssertFalse(ACECheckpointImporter.complete(checkpoint))
        try Data(#"{"weight_map":{"first":"model-00001-of-00004.safetensors","second":"model-00002-of-00004.safetensors"}}"#.utf8).write(to: checkpoint.appendingPathComponent("model.safetensors.index.json"))
        XCTAssertFalse(ACECheckpointImporter.complete(checkpoint))
        try Data([0]).write(to: checkpoint.appendingPathComponent("model-00002-of-00004.safetensors"))
        XCTAssertTrue(ACECheckpointImporter.complete(checkpoint))
    }
    func testDownloadsForDifferentEnginesRunIndependentlyAndSameEngineSerializes() async throws {
        let downloads = RuntimeDownloads()
        var release: CheckedContinuation<Void, Never>?
        var events: [String] = []
        downloads.enqueue(engine: .miniMax, model: "quality") { _ in
            events.append("mini-start")
            await withCheckedContinuation { release = $0 }
            events.append("mini-finish")
        }
        downloads.enqueue(engine: .miniMax, model: "balanced") { _ in events.append("mini-second") }
        downloads.enqueue(engine: .stableAudio, model: "sm-sfx") { _ in events.append("stable-finish") }
        for _ in 0..<100 {
            if release != nil && events.contains("stable-finish") { break }
            await Task.yield()
        }
        XCTAssertEqual(downloads.record(.miniMax, model: "quality")?.state, .running)
        XCTAssertEqual(downloads.record(.miniMax, model: "balanced")?.state, .queued)
        XCTAssertEqual(downloads.record(.stableAudio, model: "sm-sfx")?.state, .complete)
        release?.resume(); await downloads.finish()
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "mini-finish")), try XCTUnwrap(events.firstIndex(of: "mini-second")))
    }
    func testDownloadingAnotherModelDoesNotBlockComposerOrChangeWorkerPreset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(support: root, logs: root.appendingPathComponent("logs")); try paths.prepare()
        let suite = "AudiogenTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("miniMax", forKey: "engine")
        let store = GenerationStore(paths: paths, preferences: defaults)
        let mini = store.miniMax
        let runtimeRoot = mini.directory.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: mini.binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mini.binary.path)
        let manifest = mini.manifest
        let runtime = MiniMaxEngine.Runtime(sourceRevision: manifest.sourceRevision, ggmlRevision: manifest.ggmlRevision, sha256: String(repeating: "0", count: 64))
        try JSONEncoder().encode(runtime).write(to: runtimeRoot.appendingPathComponent("runtime.json"))
        try FileManager.default.createDirectory(at: mini.models, withIntermediateDirectories: true)
        for file in manifest.presets[0].models { try Data().write(to: mini.models.appendingPathComponent(file.name)) }
        try JSONEncoder().encode(manifest.presets[0]).write(to: mini.directory.appendingPathComponent("efficient.json"))
        store.prompt = "Ambient texture"
        var release: CheckedContinuation<Void, Never>?
        store.downloads.enqueue(engine: .miniMax, model: "balanced") { _ in await withCheckedContinuation { release = $0 } }
        for _ in 0..<100 { if release != nil { break }; await Task.yield() }
        XCTAssertTrue(store.canGenerate)
        XCTAssertTrue(store.canSwitchEngine)
        store.selectModel("balanced")
        XCTAssertEqual(store.modelID, "balanced")
        XCTAssertEqual(mini.presetID, "efficient")
        XCTAssertFalse(store.canGenerate)
        store.selectModel("efficient")
        XCTAssertTrue(store.canGenerate)
        release?.resume(); await store.downloads.finish()
        await store.shutdownGracefully()
    }
    func testCancelledQueuedDownloadDoesNotStartAndCanResume() async throws {
        let downloads = RuntimeDownloads()
        var release: CheckedContinuation<Void, Never>?
        var count = 0
        downloads.enqueue(engine: .musicGen, model: "small") { _ in await withCheckedContinuation { release = $0 } }
        downloads.enqueue(engine: .musicGen, model: "large") { _ in count += 1 }
        for _ in 0..<100 { if release != nil { break }; await Task.yield() }
        downloads.cancel(.musicGen, model: "large")
        XCTAssertEqual(downloads.record(.musicGen, model: "large")?.state, .interrupted)
        downloads.enqueue(engine: .musicGen, model: "large") { _ in count += 1 }
        release?.resume(); await downloads.finish()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(downloads.record(.musicGen, model: "large")?.state, .complete)
    }
}

final class LibraryRenameTests: XCTestCase {
    private func fixture() throws -> (AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(support: root, logs: root.appendingPathComponent("logs")); try paths.prepare()
        return (paths, root)
    }
    func testRenameMovesAudioUpdatesSavedReferencesAndAvoidsCollisions() async throws {
        let (paths, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let persistence = LibraryPersistence(paths: paths)
        let original = root.appendingPathComponent("old.wav")
        let existing = root.appendingPathComponent("New Name.wav")
        try Data("original audio".utf8).write(to: original); try Data("keep this".utf8).write(to: existing)
        var item = Generation(name: "old", request: GenerationRequest()); item.audio = original; item.state = .ready
        var repaint = Generation(name: "repaint", request: GenerationRequest()); repaint.request.source = original; repaint.request.reference = original
        try await persistence.save(item); try await persistence.save(repaint)
        let renamed = try await persistence.rename(item.id, name: "New Name", in: [item, repaint])
        let target = try XCTUnwrap(renamed[0].audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: target), Data("original audio".utf8))
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep this".utf8))
        XCTAssertEqual(renamed[1].request.source, target); XCTAssertEqual(renamed[1].request.reference, target)
        let saved = try await persistence.load()
        XCTAssertEqual(saved.first { $0.id == item.id }?.audio, target)
        XCTAssertEqual(saved.first { $0.id == repaint.id }?.request.source, target)
    }
    func testMetadataFailureRollsBackAudioMove() async throws {
        let (paths, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("old.wav"); try Data("audio".utf8).write(to: original)
        var item = Generation(name: "old", request: GenerationRequest()); item.audio = original
        try FileManager.default.removeItem(at: paths.metadata)
        let persistence = LibraryPersistence(paths: paths)
        do { _ = try await persistence.rename(item.id, name: "new", in: [item]); XCTFail("Saving should fail") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.wav").path))
    }
    func testFilenameSanitizationDoesNotEscapeDirectoryOrExceedByteLimit() {
        XCTAssertFalse(AudioFilename.safe("../a/b:\u{0}c").contains("/"))
        XCTAssertLessThanOrEqual(AudioFilename.safe(String(repeating: "🎵", count: 200)).utf8.count, 180)
    }
}
