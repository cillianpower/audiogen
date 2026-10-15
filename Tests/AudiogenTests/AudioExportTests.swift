import XCTest
import Foundation
import AVFoundation
@testable import Audiogen

final class AudioExportTests: XCTestCase {
    private func sine(_ frequency: Double, amplitude: Float, seconds: Double, rate: Double = 48_000, channels: Int = 1) -> AudioSamples {
        let wave = (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
        return AudioSamples(channels: Array(repeating: wave, count: channels), sampleRate: rate)
    }
    func testLoudnessMatchesBS1770ReferenceTone() {
        // A 0 dBFS 997 Hz sine on one channel reads -3.01 LUFS, at any sample rate.
        XCTAssertEqual(AudioProcessing.integratedLoudness(sine(997, amplitude: 1, seconds: 5)), -3.01, accuracy: 0.05)
        XCTAssertEqual(AudioProcessing.integratedLoudness(sine(997, amplitude: 1, seconds: 5, rate: 44_100)), -3.01, accuracy: 0.05)
        XCTAssertEqual(AudioProcessing.integratedLoudness(sine(997, amplitude: 0.1, seconds: 5)), -23.01, accuracy: 0.05)
        XCTAssertEqual(AudioProcessing.integratedLoudness(AudioSamples(channels: [[Float](repeating: 0, count: 48_000)], sampleRate: 48_000)), -.infinity)
    }
    func testLoudnessNormalizationRespectsPeakCeiling() {
        let quiet = sine(997, amplitude: 0.05, seconds: 3)
        let gain = AudioProcessing.normalizationGain(quiet, mode: .loudness)
        var louder = quiet; louder.channels = louder.channels.map { $0.map { $0 * gain } }
        XCTAssertEqual(AudioProcessing.integratedLoudness(louder), -14, accuracy: 0.05)
        // A sine at -14 LUFS peaks near -11 dBFS, so the ceiling is not reached here.
        XCTAssertLessThan(louder.peak, Float(pow(10, -1.0 / 20)))
        // Sparse clicks are quiet but peaky; the ceiling limits their gain.
        var clicks = [Float](repeating: 0, count: 48_000 * 3); for i in stride(from: 0, to: clicks.count, by: 12_000) { clicks[i] = 0.5 }
        let clickAudio = AudioSamples(channels: [clicks], sampleRate: 48_000)
        XCTAssertEqual(Double(clickAudio.peak * AudioProcessing.normalizationGain(clickAudio, mode: .loudness)), pow(10, -1.0 / 20), accuracy: 1e-4)
        XCTAssertEqual(Double(clickAudio.peak * AudioProcessing.normalizationGain(clickAudio, mode: .peak)), pow(10, -1.0 / 20), accuracy: 1e-4)
        XCTAssertEqual(AudioProcessing.normalizationGain(clickAudio, mode: .off), 1)
    }
    func testTrimSilenceKeepsRoomAndFadesEdges() {
        let rate = 48_000.0
        var samples = [Float](repeating: 0, count: Int(rate * 3))
        for i in Int(rate)..<Int(rate * 2) { samples[i] = 0.5 }
        let trimmed = AudioProcessing.trimSilence(AudioSamples(channels: [samples, samples], sampleRate: rate))
        XCTAssertEqual(trimmed.frameCount, Int(rate) + 2 * Int(rate * 0.01))
        XCTAssertEqual(trimmed.channels.count, 2)
        XCTAssertEqual(trimmed.channels[0].first, 0); XCTAssertEqual(trimmed.channels[1].last, 0)
        let silent = AudioSamples(channels: [[Float](repeating: 0, count: 100)], sampleRate: rate)
        XCTAssertEqual(AudioProcessing.trimSilence(silent).frameCount, 100)
    }
    func testRenderResamplesAndWritesTwentyFourBitWAV() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav"), output = folder.appendingPathComponent("output.wav"), copy = folder.appendingPathComponent("copy.wav")
        try sine(440, amplitude: 0.25, seconds: 2, rate: 44_100, channels: 2).writeWAV24(source)
        try AudioProcessing.render(source, to: output, options: ExportOptions(normalization: .peak, trimSilence: true, sampleRate: 48_000))
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        XCTAssertEqual(Double(file.length), 2 * 48_000, accuracy: 48_000 * 0.03)
        XCTAssertEqual(Double(try AudioSamples.read(output).peak), pow(10, -1.0 / 20), accuracy: 0.01)
        try AudioProcessing.render(source, to: copy, options: ExportOptions())
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
    }
}
