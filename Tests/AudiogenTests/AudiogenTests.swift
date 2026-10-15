import XCTest
import AVFoundation
@testable import Audiogen

final class AudiogenTests: XCTestCase {
    private func temporaryPaths() -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audiogen-tests-" + UUID().uuidString)
        return AppPaths(support: root, logs: root.appendingPathComponent("Logs"))
    }
    @MainActor func testConditioningDoesNotMutateUserPrompt() throws {
        var request = GenerationRequest()
        request.prompt = "Bowed metallic resonance"; request.noPercussion = true; request.avoid = "rhythmic pulse"
        let payload = try ACEEngine.payload(request)
        XCTAssertEqual(request.prompt, "Bowed metallic resonance")
        XCTAssertTrue((payload["prompt"] as? String ?? "").contains("No drums"))
        XCTAssertEqual(payload["lyrics"] as? String, "[Instrumental]")
        XCTAssertEqual(payload["audio_format"] as? String, "wav")
        XCTAssertEqual(payload["use_random_seed"] as? Bool, false)
        XCTAssertEqual(payload["batch_size"] as? Int, 1)
    }
    @MainActor func testRepaintRequiresRegionAndPreservesInterval() throws {
        var request = GenerationRequest(); request.prompt = "glass"; request.mode = .repaint
        XCTAssertThrowsError(try ACEEngine.payload(request))
        request.source = URL(fileURLWithPath: "/tmp/original.wav")
        request.region = AudioRegion(start: 12.4, end: 18.7)
        let payload = try ACEEngine.payload(request)
        XCTAssertEqual(payload["task_type"] as? String, "repaint")
        XCTAssertEqual(payload["src_audio_path"] as? String, "/tmp/original.wav")
        XCTAssertEqual(payload["repainting_start"] as? Double, 12.4)
        XCTAssertEqual(payload["repainting_end"] as? Double, 18.7)
        XCTAssertEqual(payload["chunk_mask_mode"] as? String, "explicit")
        request.region = AudioRegion(start: 20, end: 10)
        XCTAssertThrowsError(try ACEEngine.payload(request))
    }
    @MainActor func testRejectsInvalidDurationAndEmptyPrompt() {
        var request = GenerationRequest()
        XCTAssertThrowsError(try ACEEngine.payload(request))
        request.prompt = "texture"; request.duration = 0
        XCTAssertThrowsError(try ACEEngine.payload(request))
    }
    func testManifestPinsEveryArtifact() throws {
        let manifest = try EngineManifest.bundled()
        XCTAssertEqual(manifest.platform, "macos-arm64")
        XCTAssertEqual(manifest.sourceRevision.count, 40)
        XCTAssertEqual(manifest.modelRevision.count, 40)
        for artifact in [manifest.runtime, manifest.python, manifest.repository] + manifest.models {
            XCTAssertEqual(artifact.sha256.count, 64)
            XCTAssertEqual(artifact.url.scheme, "https")
            XCTAssertFalse(artifact.url.absoluteString.contains("/main/"))
            XCTAssertFalse(artifact.name.contains(".."))
        }
        for directory in ["vae/", "Qwen3-Embedding-0.6B/", "acestep-v15-turbo/", "acestep-5Hz-lm-1.7B/"] {
            XCTAssertTrue(manifest.models.contains { $0.name.hasPrefix(directory) && $0.name.hasSuffix("safetensors") })
        }
    }
    func testMetadataRoundTripAndInterruptedJobRecovery() async throws {
        let paths = temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.support) }
        try paths.prepare()
        let persistence = LibraryPersistence(paths: paths)
        var request = GenerationRequest(); request.prompt = "Test texture"; request.seed = 42
        var item = Generation(name: "texture", request: request)
        item.state = .generating
        try await persistence.save(item)
        let loaded = try await persistence.load()
        XCTAssertEqual(loaded.first?.id, item.id)
        XCTAssertEqual(loaded.first?.request.seed, 42)
        XCTAssertEqual(loaded.first?.state, .failed)
        XCTAssertNotNil(loaded.first?.error)
    }
    func testRemovingMetadataKeepsDraggedAudio() async throws {
        let paths = temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.support) }
        try paths.prepare()
        let audio = paths.support.appendingPathComponent("existing.wav")
        try Data("audio".utf8).write(to: audio)
        var item = Generation(name: "keep", request: GenerationRequest()); item.audio = audio; item.state = .ready
        let persistence = LibraryPersistence(paths: paths)
        try await persistence.save(item); try await persistence.delete(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let loaded = try await persistence.load(); XCTAssertTrue(loaded.isEmpty)
    }
    func testChecksumRejectsModifiedDownload() async throws {
        let paths = temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.support) }
        try paths.prepare(); let file = paths.support.appendingPathComponent("artifact")
        try Data("abc".utf8).write(to: file)
        let verifier = FileVerifier()
        let valid = try await verifier.matches(file, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(valid)
        try Data("corrupt".utf8).write(to: file)
        let invalid = try await verifier.matches(file, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertFalse(invalid)
    }
    func testWaveformStreamingAndCacheAtSourceRate() async throws {
        let paths = temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.support) }
        try paths.prepare()
        let file = paths.support.appendingPathComponent("source.wav")
        try writeTone(file)
        let files = AudioFiles(); let cache = paths.peaks.appendingPathComponent("peaks.json")
        let peaks = try await files.waveform(file, cache: cache)
        XCTAssertEqual(peaks.duration, 1, accuracy: 0.001)
        XCTAssertEqual(peaks.peaks.count, 1200)
        XCTAssertGreaterThan(peaks.peaks.max() ?? 0, 0.49)
        try FileManager.default.removeItem(at: file)
        let cached = try await files.waveform(file, cache: cache)
        XCTAssertEqual(cached.peaks, peaks.peaks)
    }
    func testGeneratedWAVIsPCM24WithoutUpsampling() async throws {
        let paths = temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.support) }
        try paths.prepare()
        let url = paths.support.appendingPathComponent("generated.wav")
        try writeTone(url)
        let files = AudioFiles()
        try await files.prepareGeneratedWAV(url)
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        XCTAssertEqual(audio.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(audio.fileFormat.channelCount, 2)
        XCTAssertEqual(audio.length, 44_100)
    }
    func testReferenceConversionPreservesOriginalAndSampleRate() async throws {
        let paths = temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.support) }
        try paths.prepare()
        let original = paths.support.appendingPathComponent("resonance.aiff")
        try writeTone(original)
        let originalBytes = try Data(contentsOf: original)
        let converted = try await AudioFiles().importReference(original, directory: paths.references)
        XCTAssertEqual(converted.pathExtension, "wav")
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        let copiedOriginal = converted.deletingLastPathComponent().appendingPathComponent("resonance.aiff")
        XCTAssertEqual(try Data(contentsOf: copiedOriginal), originalBytes)
        let file = try AVAudioFile(forReading: converted)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.length, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
    }
    private func writeTone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for channel in 0..<2 { for frame in 0..<44_100 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100)) * 0.5 } }
        try file.write(from: buffer)
    }
}
