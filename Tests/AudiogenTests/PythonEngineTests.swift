import XCTest
import Foundation
import AVFoundation
@testable import Audiogen

@MainActor final class PythonEngineTests: XCTestCase {
    func testCatalogPinsSourcesAndAllRequiredModels() throws {
        let catalog = try RuntimeCatalog.bundled()
        XCTAssertEqual(Set(catalog.runtimes.map(\.id)), Set([.stableAudio, .musicGen, .yue]))
        for runtime in catalog.runtimes {
            XCTAssertEqual(runtime.revision.count, 40)
            XCTAssertEqual(runtime.repository.sha256.count, 64)
            XCTAssertTrue(runtime.repository.url.absoluteString.contains(runtime.revision))
            XCTAssertFalse(runtime.models.isEmpty)
            for model in runtime.models {
                XCTAssertFalse(model.files.isEmpty)
                for file in model.files {
                    XCTAssertEqual(file.sha256.count, 64)
                    XCTAssertEqual(file.url.scheme, "https")
                    XCTAssertGreaterThan(file.bytes, 0)
                    XCTAssertFalse(file.name.split(separator: "/").contains(".."))
                }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: RuntimeCatalog.resourceRoot.appendingPathComponent(runtime.id.rawValue).appendingPathComponent("uv.lock").path))
        }
    }
    func testNewEngineSnapshotsPreserveTheirModelIdentity() {
        var request = GenerationRequest(); request.model = "sm-sfx"
        let plan = GenerationPlan.requests(base: request, selected: .stableAudio, both: false, aceModel: .turbo, miniMaxModel: "efficient", miniMaxSteps: 20)
        XCTAssertEqual(plan[0].1.model, "sm-sfx")
        var generation = Generation(name: "sound", request: request)
        generation.engineID = .stableAudio; generation.engine = EngineID.stableAudio.name
        XCTAssertEqual(generation.resolvedEngineID, .stableAudio)
    }
    func testLiveInstallAndGenerate() async throws {
        guard let base = ProcessInfo.processInfo.environment["AUDIOGEN_RUNTIME_TEST_ROOT"] else { throw XCTSkip("Opt-in pinned runtime installation and real generation test") }
        let chosen = ProcessInfo.processInfo.environment["AUDIOGEN_PYTHON_ENGINE"].flatMap { $0.isEmpty ? nil : $0 }
        let root = URL(fileURLWithPath: base)
        let paths = AppPaths(support: root, logs: root.appendingPathComponent("Logs"))
        let specs = try RuntimeCatalog.bundled().runtimes.filter { chosen == nil || $0.id.rawValue == chosen }
        guard !specs.isEmpty else { XCTFail("Unknown Python runtime selection"); return }
        for spec in specs {
            let engine = PythonEngine(paths: paths, spec: spec)
            do {
                var last = Date.distantPast
                try await engine.install { status, progress in
                    if Date().timeIntervalSince(last) > 5 { print("\(spec.id.name): \(status) \(progress.map { String(format: "%.1f%%", $0 * 100) } ?? "")"); fflush(stdout); last = Date() }
                }
                XCTAssertTrue(engine.installed)
                try await engine.start()
                var request = GenerationRequest(); request.model = engine.modelID
                request.prompt = "A quiet ambient synthesizer pad, warm sustained harmonics, instrumental"
                request.seed = 42; request.duration = 10; request.steps = spec.id == .musicGen ? 1 : 2
                let job = try await engine.generate(request)
                var result: EngineResult?
                for _ in 0..<900 {
                    result = try await engine.result(job)
                    if result != nil { break }
                    try await Task.sleep(for: .seconds(2))
                }
                let output = try XCTUnwrap(result)
                let destination = root.appendingPathComponent("Renders/\(spec.id.rawValue).wav")
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try await engine.download(output, to: destination)
                try await AudioFiles().prepareGeneratedWAV(destination)
                let audio = try AVAudioFile(forReading: destination)
                XCTAssertGreaterThan(audio.length, 0)
                XCTAssertEqual(audio.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
                print("Rendered \(spec.id.name): \(Double(audio.length) / audio.processingFormat.sampleRate)s at \(audio.processingFormat.sampleRate) Hz")
                await engine.stop()
                let cancelled = try await engine.generate(request)
                XCTAssertTrue(engine.ownsServer)
                try await engine.cancel(cancelled)
                XCTAssertFalse(engine.ownsServer)
            } catch { await engine.stop(); throw error }
        }
    }
}
