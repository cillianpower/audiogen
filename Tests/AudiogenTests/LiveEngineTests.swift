import XCTest
import Foundation
import AVFoundation
@testable import Audiogen

@MainActor final class LiveEngineTests: XCTestCase {
    func testInstallStartGenerateAndRepaint() async throws {
        guard let root = ProcessInfo.processInfo.environment["AUDIOGEN_INTEGRATION_ROOT"] else { throw XCTSkip("Opt-in real engine test; see scripts/check-engine.sh") }
        let paths = AppPaths(support: URL(fileURLWithPath: root), logs: URL(fileURLWithPath: root).appendingPathComponent("Logs"))
        let engine = ACEEngine(paths: paths, manifest: try .bundled())
        do {
            var previousStatus = ""
            try await engine.install { status, _ in if status != previousStatus { print(status); previousStatus = status } }
            XCTAssertTrue(engine.installer.installed)
            try await engine.start()
            let ready = await engine.health(); XCTAssertTrue(ready)
            var request = GenerationRequest(); request.prompt = "Soft bowed metallic resonance, slow decaying texture"; request.duration = 10; request.steps = 2; request.seed = 42; request.noPercussion = true
            try await engine.configureLoRA(request)
            let job = try await engine.generate(request)
            let result = try await wait(engine, job: job)
            let outputs = paths.support.appendingPathComponent("Renders/" + UUID().uuidString)
            let audio = outputs.appendingPathComponent("smoke-test.wav")
            try await engine.download(result, to: audio)
            try await AudioFiles().prepareGeneratedWAV(audio)
            let file = try AVAudioFile(forReading: audio)
            XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
            XCTAssertGreaterThan(file.length, 0)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            print("Generated \(duration) seconds at \(file.processingFormat.sampleRate) Hz")
            request.reference = audio; request.source = audio; request.duration = duration; request.region = AudioRegion(start: 2, end: 4); request.mode = .repaint
            let repaint = try await engine.generate(request)
            let repainted = try await wait(engine, job: repaint)
            let repaintAudio = outputs.appendingPathComponent("smoke-repaint.wav")
            try await engine.download(repainted, to: repaintAudio)
            try await AudioFiles().prepareGeneratedWAV(repaintAudio)
            let repaintFile = try AVAudioFile(forReading: repaintAudio)
            XCTAssertEqual(repaintFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
            XCTAssertEqual(Double(repaintFile.length) / repaintFile.processingFormat.sampleRate, duration, accuracy: 0.5)
            await engine.stop()
            XCTAssertFalse(engine.ownsServer)
        } catch { await engine.stop(); throw error }
    }
    private func wait(_ engine: ACEEngine, job: GenerationJob) async throws -> EngineResult {
        for _ in 0..<450 {
            if let result = try await engine.result(job) { return result }
            try await Task.sleep(for: .seconds(2))
        }
        throw AppError.message("Live render timed out.")
    }
}
