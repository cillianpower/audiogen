import XCTest
import Foundation
import AVFoundation
@testable import Audiogen

@MainActor final class ImportAndClipTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func ramp(_ url: URL, seconds: Double = 1, rate: Double = 48_000) throws -> AudioSamples {
        let frames = Int(seconds * rate)
        let audio = AudioSamples(channels: [(0..<frames).map { Float($0) / Float(frames) - 0.5 }, (0..<frames).map { 0.5 - Float($0) / Float(frames) }], sampleRate: rate)
        try audio.writeWAV24(url)
        return audio
    }
    private func makeStore() async throws -> (GenerationStore, () -> Void) {
        let paths = AppPaths(support: root.appendingPathComponent("Support"), logs: root.appendingPathComponent("Logs")); try paths.prepare()
        let suite = "AudiogenTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(root.appendingPathComponent("Library").path, forKey: "outputDirectory")
        let store = GenerationStore(paths: paths, preferences: defaults)
        for _ in 0..<500 where store.engineStatus == "Not Installed" { try await Task.sleep(for: .milliseconds(10)) }
        return (store, { defaults.removePersistentDomain(forName: suite) })
    }

    func testClipKeepsExactSamplesAndIsReused() throws {
        let source = root.appendingPathComponent("loop.wav")
        let audio = try ramp(source)
        let clip = try AudioClips.clip(of: source, region: AudioRegion(start: 0.25, end: 0.5))
        XCTAssertEqual(clip.deletingLastPathComponent().lastPathComponent, "Clips")
        XCTAssertEqual(clip.lastPathComponent, "loop 0.25-0.50s.wav")
        let read = try AudioSamples.read(clip)
        XCTAssertEqual(read.frameCount, 12_000); XCTAssertEqual(read.channels.count, 2)
        XCTAssertEqual(read.channels[0][0], audio.channels[0][12_000], accuracy: 1e-6)
        XCTAssertEqual(read.channels[1][11_999], audio.channels[1][23_999], accuracy: 1e-6)
        XCTAssertEqual(try AVAudioFile(forReading: clip).fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        XCTAssertEqual(try AudioClips.clip(of: source, region: AudioRegion(start: 0.25, end: 0.5)), clip)
        XCTAssertThrowsError(try AudioClips.clip(of: source, region: AudioRegion(start: 2, end: 3)))
    }
    func testDragFileUsesSelectionWhenPresent() throws {
        let source = root.appendingPathComponent("drag.wav"); _ = try ramp(source)
        let player = AudioPlayer(); player.url = source
        XCTAssertEqual(try AudioClips.dragFile(for: player), source)
        player.selection = AudioRegion(start: 0.1, end: 0.3)
        XCTAssertEqual(try AudioClips.dragFile(for: player)?.lastPathComponent, "drag 0.10-0.30s.wav")
    }
    func testImportAddsWAVUnchangedAndConvertsAIFF() async throws {
        let (store, cleanup) = try await makeStore(); defer { cleanup() }
        let wav = root.appendingPathComponent("Bounce 1.wav"); _ = try ramp(wav, seconds: 2)
        // A 16-bit AIFF, as some DAWs bounce.
        let aiff = root.appendingPathComponent("Resample.aiff")
        do {
            let file = try AVAudioFile(forWriting: aiff, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)); buffer.frameLength = 44_100
            for i in 0..<44_100 { buffer.floatChannelData![0][i] = 0.25 * Float(sin(Double(i) * 0.05)) }
            try file.write(from: buffer)
        }
        let notes = root.appendingPathComponent("notes.txt"); try Data("x".utf8).write(to: notes)
        store.searchText = "nothing matches this"
        store.importAudio([wav, aiff, notes])
        for _ in 0..<300 where store.generations.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.generations.count, 2)
        let imported = store.generations.filter(\.isImported)
        XCTAssertEqual(Set(imported.map(\.name)), ["Bounce 1", "Resample"])
        for item in imported {
            XCTAssertEqual(item.state, .ready); XCTAssertEqual(item.source, .imported)
            XCTAssertEqual(item.audio?.pathExtension, "wav")
            XCTAssertEqual(item.audio?.deletingLastPathComponent().lastPathComponent, "Imported")
        }
        let bounce = try XCTUnwrap(imported.first { $0.name == "Bounce 1" })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(bounce.audio)), try Data(contentsOf: wav))
        XCTAssertEqual(bounce.actualDuration ?? 0, 2, accuracy: 0.01)
        let resample = try XCTUnwrap(imported.first { $0.name == "Resample" })
        XCTAssertEqual(resample.actualDuration ?? 0, 1, accuracy: 0.01)
        // Importing clears filters that would hide the new audio, and selects it.
        XCTAssertEqual(store.searchText, "")
        XCTAssertTrue(imported.map(\.id).contains(try XCTUnwrap(store.selectedID)))
        store.sourceFilter = .imported
        XCTAssertEqual(store.visibleGenerations.count, 2)
        store.sourceFilter = .engine(.ace)
        XCTAssertTrue(store.visibleGenerations.isEmpty)
        // Imported audio is not reloaded as generation settings.
        store.seedText = "77"; store.duplicateSettings(bounce, variation: true)
        XCTAssertEqual(store.seedText, "77"); XCTAssertEqual(store.generations.count, 2)
        // Records survive a reload.
        let saved = try await LibraryPersistence(paths: store.paths).load()
        XCTAssertEqual(saved.filter(\.isImported).count, 2)
        await store.shutdownGracefully()
    }
    func testComposerDropUsesReferenceOnlyWhenEngineSupportsIt() async throws {
        let (store, cleanup) = try await makeStore(); defer { cleanup() }
        let wav = root.appendingPathComponent("ref.wav"); _ = try ramp(wav)
        XCTAssertFalse(store.dropOnComposer([root.appendingPathComponent("notes.txt")]))
        store.selectEngine(.ace)
        XCTAssertTrue(store.dropOnComposer([wav]))
        for _ in 0..<300 where store.reference == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.reference?.lastPathComponent, "ref.wav")
        XCTAssertTrue(store.generations.isEmpty)
        store.clearReference(); store.selectEngine(.miniMax)
        XCTAssertTrue(store.dropOnComposer([wav]))
        for _ in 0..<300 where store.generations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.generations.first?.isImported, true)
        XCTAssertNil(store.reference)
        await store.shutdownGracefully()
    }
    func testRepaintSelectionLeavesComposerMode() async throws {
        let (store, cleanup) = try await makeStore(); defer { cleanup() }
        store.selectEngine(.stableAudio)
        store.mode = .generate; store.repaintSelection()
        XCTAssertEqual(store.mode, .generate)
        store.mode = .repaint; store.repaintSelection()
        XCTAssertEqual(store.mode, .repaint)
        await store.shutdownGracefully()
    }
}
