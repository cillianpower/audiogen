import XCTest
import Foundation
import AVFoundation
@testable import Audiogen

@MainActor final class ProcessingTests: XCTestCase {
    func testSharedSchedulerOrdersJobsAndCancelledWaiterDoesNotTakeLease() async throws {
        let scheduler = AudioWorkScheduler()
        let first = UUID(), second = UUID(), third = UUID()
        try await scheduler.acquire(first)
        let cancelled = Task { try await scheduler.acquire(second) }
        for _ in 0..<20 { await Task.yield() }
        let next = Task { try await scheduler.acquire(third) }
        for _ in 0..<20 { await Task.yield() }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled job acquired a lease") } catch is CancellationError {} 
        XCTAssertEqual(scheduler.owner, first)
        scheduler.release(second)
        XCTAssertEqual(scheduler.owner, first)
        scheduler.release(first)
        try await next.value
        XCTAssertEqual(scheduler.owner, third)
        scheduler.release(third)
        XCTAssertNil(scheduler.owner)
    }
    func testAnchorBoundsAndLongClipRules() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        var request = ProcessingRequest(engine: .sam, model: "small", source: input, description: "bells", duration: 40)
        XCTAssertNoThrow(try request.validate())
        request.anchors = [ExtractionAnchor(present: true, region: AudioRegion(start: 1, end: 2))]
        XCTAssertThrowsError(try request.validate())
        request.duration = 10
        XCTAssertNoThrow(try request.validate())
        request.anchors[0].region.end = 11
        XCTAssertThrowsError(try request.validate())
        request.anchors = []; request.description = " "
        XCTAssertThrowsError(try request.validate())
    }
    func testProcessingHistoryRecoversInterruptedJobsAndKeepsNamedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.wav"); try Data([0]).write(to: input)
        let persistence = ProcessingPersistence(paths: AppPaths(support: root, logs: root.appendingPathComponent("logs")))
        let request = ProcessingRequest(engine: .sam, model: "small", source: input, description: "bells", duration: 10)
        var completed = ProcessingRecord(name: "bells", request: request, sourceRevision: "pinned")
        completed.state = .ready
        completed.outputs = [ProcessingOutput(role: .extracted, file: input, duration: 10), ProcessingOutput(role: .remaining, file: input, duration: 10)]
        let interrupted = ProcessingRecord(name: "interrupted", request: request, sourceRevision: "pinned")
        try await persistence.save(completed); try await persistence.save(interrupted)
        let records = try await persistence.load()
        XCTAssertEqual(records.first { $0.id == completed.id }?.outputs.map(\.role), [.extracted, .remaining])
        XCTAssertEqual(records.first { $0.id == interrupted.id }?.state, .cancelled)
        try await persistence.remove(completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }
    func testProcessingCatalogContainsPinnedModelsAndSeparateWorkspaces() throws {
        let runtimes = try ProcessingCatalog.bundled().runtimes
        XCTAssertEqual(Set(runtimes.map(\.id)), [.sam, .after])
        XCTAssertFalse(EngineID.generationCases.contains(.sam)); XCTAssertFalse(EngineID.generationCases.contains(.after))
        for runtime in runtimes {
            XCTAssertEqual(runtime.revision.count, 40)
            XCTAssertEqual(runtime.repository.sha256.count, 64)
            for model in runtime.models { for file in model.files {
                XCTAssertEqual(file.sha256.count, 64)
                XCTAssertGreaterThan(file.bytes, 0)
            } }
        }
    }
    func testLiveProcessingAndCancellation() async throws {
        guard let location = ProcessInfo.processInfo.environment["AUDIOGEN_PROCESSING_TEST_ROOT"] else { throw XCTSkip("Opt-in real SAM/AFTER processing test") }
        let root = URL(fileURLWithPath: location)
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/python-smoke/Renders/stableAudio.wav")
        let chosen = ProcessInfo.processInfo.environment["AUDIOGEN_PROCESSING_ENGINE"]
        for spec in try ProcessingCatalog.bundled().runtimes where chosen == nil || chosen == spec.id.rawValue {
            let engine = PythonEngine(paths: AppPaths(support: root, logs: root.appendingPathComponent("Logs")), spec: spec)
            do {
                try await engine.install { status, _ in print(status) }
                let request = ProcessingRequest(engine: spec.id, model: engine.modelID, source: source,
                    reference: spec.id == .after ? source : nil, description: "synthesizer", steps: 2, duration: 10)
                let job = try await engine.process(request)
                var result: (ProcessingWorkerResult, URL, String)?
                for _ in 0..<600 {
                    result = try engine.processingResult(job)
                    if result != nil { break }
                    try await Task.sleep(for: .seconds(1))
                }
                let output = try XCTUnwrap(result)
                XCTAssertEqual(output.0.outputs.count, spec.id == .sam ? 2 : 1)
                let destination = root.appendingPathComponent("Renders/\(spec.id.rawValue)")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for artifact in output.0.outputs {
                    let url = output.1.appendingPathComponent(artifact.filename)
                    let audio = try AVAudioFile(forReading: url)
                    XCTAssertEqual(Double(audio.length)/audio.processingFormat.sampleRate, 10, accuracy: 0.01)
                    XCTAssertEqual(audio.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
                    let copy = destination.appendingPathComponent(artifact.filename)
                    try? FileManager.default.removeItem(at: copy)
                    try FileManager.default.copyItem(at: url, to: copy)
                }
                engine.finishProcessing(); await engine.stop()
                _ = try await engine.process(request)
                XCTAssertTrue(engine.ownsServer)
                await engine.stop()
                XCTAssertFalse(engine.ownsServer)
            } catch { await engine.stop(); throw error }
        }
    }
}
