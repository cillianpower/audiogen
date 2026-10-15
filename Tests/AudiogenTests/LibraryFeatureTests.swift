import XCTest
import Foundation
import AppKit
@testable import Audiogen

@MainActor final class LibraryFeatureTests: XCTestCase {
    func testTakeSeedsKeepFirstSeedAndStayDistinct() {
        var sequence: [Int64] = [7, 9, 9, 11, 12]
        XCTAssertEqual(GenerationPlan.seeds(first: 7, takes: 4) { sequence.removeFirst() }, [7, 9, 11, 12])
        XCTAssertEqual(GenerationPlan.seeds(first: 3, takes: 1), [3])
        XCTAssertEqual(Set(GenerationPlan.seeds(first: 1, takes: 4)).count, 4)
    }
    func testShortDurationsOnlyForEnginesThatRenderThem() {
        XCTAssertEqual(EngineID.stableAudio.durationChoices.prefix(3), [1, 2, 5])
        XCTAssertEqual(EngineID.musicGen.durationChoices.first, 1)
        for id in [EngineID.ace, .miniMax, .yue] { XCTAssertEqual(id.durationChoices.first, 10) }
    }
    func testACEProgressReadsRunningTaskResult() {
        XCTAssertEqual(ACEEngine.progress(["status": 0, "result": #"[{"progress": 0.42, "stage": "diffusion"}]"#]), 0.42)
        XCTAssertNil(ACEEngine.progress(["status": 0, "result": #"[{"progress": 0, "stage": "queued"}]"#]))
        XCTAssertNil(ACEEngine.progress(["status": 0, "result": "[]"]))
        XCTAssertNil(ACEEngine.progress(["status": 0]))
    }
    func testOlderRecordsDecodeWithoutNewFields() throws {
        let generation = Generation(name: "Old", request: GenerationRequest())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(generation)) as? [String: Any])
        json.removeValue(forKey: "starred")
        XCTAssertFalse(try JSONDecoder().decode(Generation.self, from: JSONSerialization.data(withJSONObject: json)).isStarred)
        let request = ProcessingRequest(engine: .sam, model: "small", source: URL(fileURLWithPath: "/a.wav"), description: "bells", duration: 4)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        json.removeValue(forKey: "stereo")
        XCTAssertNil(try JSONDecoder().decode(ProcessingRequest.self, from: JSONSerialization.data(withJSONObject: json)).stereo)
    }

    private func makeStore(_ items: [Generation] = []) async throws -> (GenerationStore, AppPaths, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(support: root, logs: root.appendingPathComponent("logs")); try paths.prepare()
        let persistence = LibraryPersistence(paths: paths)
        for item in items { try await persistence.save(item) }
        let suite = "AudiogenTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = GenerationStore(paths: paths, preferences: defaults)
        for _ in 0..<500 where store.engineStatus == "Not Installed" { try await Task.sleep(for: .milliseconds(10)) }
        return (store, paths, { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) })
    }
    private func item(_ name: String, prompt: String, engine: EngineID, starred: Bool = false, age: TimeInterval) -> Generation {
        var request = GenerationRequest(); request.prompt = prompt
        var item = Generation(name: name, created: Date().addingTimeInterval(-age), request: request, state: .ready)
        item.engine = engine.name; item.engineID = engine; item.starred = starred ? true : nil
        return item
    }

    func testSearchFilterStarAndUndoableDelete() async throws {
        let pad = item("Warm pad", prompt: "warm analog pad", engine: .ace, starred: true, age: 30)
        let bells = item("Bells", prompt: "glass bells", engine: .stableAudio, age: 20)
        let drone = item("Drone", prompt: "warm cello drone", engine: .miniMax, age: 10)
        let (store, paths, cleanup) = try await makeStore([pad, bells, drone])
        defer { cleanup() }
        XCTAssertEqual(store.generations.map(\.name), ["Drone", "Bells", "Warm pad"])
        store.searchText = "WARM"
        XCTAssertEqual(store.visibleGenerations.map(\.name), ["Drone", "Warm pad"])
        store.starredOnly = true
        XCTAssertEqual(store.visibleGenerations.map(\.name), ["Warm pad"])
        store.searchText = ""; store.starredOnly = false; store.sourceFilter = .engine(.stableAudio)
        XCTAssertEqual(store.visibleGenerations.map(\.name), ["Bells"])
        store.sourceFilter = nil
        XCTAssertFalse(store.isFiltering)

        store.toggleStar(bells.id)
        XCTAssertTrue(try XCTUnwrap(store.generations.first { $0.id == bells.id }).isStarred)
        var saved = false
        for _ in 0..<200 where !saved {
            saved = try await LibraryPersistence(paths: paths).load().first { $0.id == bells.id }?.isStarred == true
            if !saved { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(saved)

        let undo = UndoManager(); undo.groupsByEvent = false
        let file = paths.metadata.appendingPathComponent(pad.id.uuidString + ".json")
        func waitFor(_ exists: Bool) async throws {
            for _ in 0..<200 where FileManager.default.fileExists(atPath: file.path) != exists { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), exists)
        }
        undo.beginUndoGrouping(); store.delete(pad.id, undoManager: undo); undo.endUndoGrouping()
        XCTAssertFalse(store.generations.contains { $0.id == pad.id })
        try await waitFor(false)
        XCTAssertEqual(undo.undoActionName, "Delete Generation")
        undo.undo()
        XCTAssertEqual(store.generations.map(\.name), ["Drone", "Bells", "Warm pad"])
        XCTAssertEqual(store.selectedID, pad.id)
        try await waitFor(true)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertFalse(store.generations.contains { $0.id == pad.id })
        try await waitFor(false)
        await store.shutdownGracefully()
    }
    func testSwitchingToALongFormEngineRaisesShortDuration() async throws {
        let (store, _, cleanup) = try await makeStore()
        defer { cleanup() }
        store.selectEngine(.stableAudio)
        XCTAssertTrue(store.durationChoices.contains(2))
        store.duration = 2
        store.selectEngine(.ace)
        XCTAssertEqual(store.duration, 10)
        XCTAssertFalse(store.durationChoices.contains(2))
        await store.shutdownGracefully()
    }
    func testTakesQueueSeparateSeeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(support: root, logs: root.appendingPathComponent("logs")); try paths.prepare()
        let suite = "AudiogenTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("miniMax", forKey: "engine")
        let store = GenerationStore(paths: paths, preferences: defaults)
        // Mark MiniMax's first preset as installed so the composer can queue work.
        let mini = store.miniMax, manifest = mini.manifest
        let runtimeRoot = mini.directory.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: mini.binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mini.binary.path)
        try JSONEncoder().encode(MiniMaxEngine.Runtime(sourceRevision: manifest.sourceRevision, ggmlRevision: manifest.ggmlRevision, sha256: String(repeating: "0", count: 64))).write(to: runtimeRoot.appendingPathComponent("runtime.json"))
        try FileManager.default.createDirectory(at: mini.models, withIntermediateDirectories: true)
        for file in manifest.presets[0].models { try Data().write(to: mini.models.appendingPathComponent(file.name)) }
        try JSONEncoder().encode(manifest.presets[0]).write(to: mini.directory.appendingPathComponent("efficient.json"))
        for _ in 0..<500 where store.engineStatus == "Not Installed" { try await Task.sleep(for: .milliseconds(10)) }
        store.prompt = "Slow evolving strings"; store.seedText = "123"; store.takes = 4
        XCTAssertTrue(store.canGenerate)
        store.generate()
        store.shutdown() // Stop before the queue reaches the stand-in runtime.
        let queued = store.generations
        XCTAssertEqual(queued.count, 4)
        XCTAssertEqual(Set(queued.map(\.request.seed)).count, 4)
        XCTAssertTrue(queued.contains { $0.request.seed == 123 && $0.name.hasSuffix("take 1") })
        XCTAssertEqual(Set(queued.map { $0.name.components(separatedBy: " take ").last! }), ["1", "2", "3", "4"])
        XCTAssertEqual(defaults.integer(forKey: "takes"), 4)
        await store.shutdownGracefully()
    }
}

@MainActor final class WaveformKeyboardTests: XCTestCase {
    private func press(_ view: WaveformNSView, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        let characters = String(UnicodeScalar(UInt8(code == 123 ? 28 : code == 124 ? 29 : 27)))
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
    }
    func testArrowKeysMovePlayheadAndShiftSelects() {
        let player = AudioPlayer(); player.duration = 10; player.seek(4)
        let view = WaveformNSView(); view.player = player
        press(view, 124); XCTAssertEqual(player.time, 5)
        press(view, 123, .option); XCTAssertEqual(player.time, 4.9, accuracy: 1e-9)
        press(view, 124, .shift); press(view, 124, .shift)
        XCTAssertEqual(player.selection?.start ?? -1, 4.9, accuracy: 1e-9); XCTAssertEqual(player.selection?.end ?? -1, 6.9, accuracy: 1e-9)
        // Extending back past the starting point flips the selection around it.
        press(view, 123, .shift); press(view, 123, .shift); press(view, 123, .shift)
        XCTAssertEqual(player.selection?.start ?? -1, 3.9, accuracy: 1e-9); XCTAssertEqual(player.selection?.end ?? -1, 4.9, accuracy: 1e-9)
        XCTAssertEqual(player.time, 3.9, accuracy: 1e-9)
        press(view, 124, .command); XCTAssertEqual(player.time, 10)
        XCTAssertNotNil(player.selection)
        press(view, 53); XCTAssertNil(player.selection)
        press(view, 123, .command); XCTAssertEqual(player.time, 0)
        press(view, 123); XCTAssertEqual(player.time, 0)
    }
}

@MainActor final class DockTileTests: XCTestCase {
    func testTileDrawsCountBadgeAndProgress() throws {
        let view = DockActivity.TileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        view.count = 3; view.fraction = 0.5
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["AUDIOGEN_TILE_PNG"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder)) }
        // The badge sits in the top-right corner; bitmap rows start at the top.
        let badge = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - Int(Double(rep.pixelsWide) * 0.1), y: Int(Double(rep.pixelsHigh) * 0.15))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(badge.redComponent, 0.8); XCTAssertLessThan(badge.greenComponent, 0.4)
        view.count = 0; view.fraction = nil
        let idle = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: idle)
        let empty = try XCTUnwrap(idle.colorAt(x: idle.pixelsWide - Int(Double(idle.pixelsWide) * 0.1), y: Int(Double(idle.pixelsHigh) * 0.15))?.usingColorSpace(.sRGB))
        XCTAssertFalse(empty.redComponent > 0.8 && empty.greenComponent < 0.4)
    }
}
