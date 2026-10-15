import Foundation
import AVFoundation
import AppKit
import SwiftUI
import Observation

enum ExportNormalization: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, peak, loudness
    var id: Self { self }
    var title: String {
        switch self { case .off: "Off"; case .peak: "Peak −1 dBFS"; case .loudness: "Loudness −14 LUFS" }
    }
}
struct ExportOptions: Codable, Equatable, Sendable {
    var normalization: ExportNormalization = .off
    var trimSilence = false
    /// nil keeps the source sample rate.
    var sampleRate: Double?
    var isPassthrough: Bool { normalization == .off && !trimSilence && sampleRate == nil }
    static let peakCeiling = -1.0
    static let loudnessTarget = -14.0
}

/// Float audio held as one array per channel.
struct AudioSamples: Sendable {
    var channels: [[Float]]
    var sampleRate: Double
    var frameCount: Int { channels.first?.count ?? 0 }
    var peak: Float { channels.map { $0.map(abs).max() ?? 0 }.max() ?? 0 }
    static func read(_ url: URL) throws -> Self {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw AppError.message("This audio file is empty or unsupported.") }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw AppError.message("This audio format could not be read.") }
        let frames = Int(buffer.frameLength)
        return Self(channels: (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }, sampleRate: format.sampleRate)
    }
    func writeWAV24(_ url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels.count, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, frameCount))), let data = buffer.floatChannelData else { throw AppError.message("This audio could not be written.") }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for (index, channel) in channels.enumerated() { channel.withUnsafeBufferPointer { data[index].update(from: $0.baseAddress!, count: frameCount) } }
        try file.write(from: buffer)
    }
}

enum AudioProcessing {
    /// Removes leading and trailing audio below -60 dBFS, keeping 10 ms of room,
    /// then applies a 5 ms fade-in and 20 ms fade-out so edges never click.
    static func trimSilence(_ audio: AudioSamples, threshold: Float = 0.001) -> AudioSamples {
        let frames = audio.frameCount
        func loud(_ frame: Int) -> Bool { audio.channels.contains { abs($0[frame]) > threshold } }
        guard let first = (0..<frames).first(where: loud), let last = (0..<frames).last(where: loud) else { return audio }
        let room = Int(audio.sampleRate * 0.01)
        let start = max(0, first - room), end = min(frames, last + 1 + room)
        var trimmed = AudioSamples(channels: audio.channels.map { Array($0[start..<end]) }, sampleRate: audio.sampleRate)
        fade(&trimmed, in: 0.005, out: 0.02)
        return trimmed
    }
    static func fade(_ audio: inout AudioSamples, in fadeIn: Double, out fadeOut: Double) {
        let frames = audio.frameCount
        let inFrames = min(frames / 2, Int(audio.sampleRate * fadeIn)), outFrames = min(frames / 2, Int(audio.sampleRate * fadeOut))
        for index in audio.channels.indices {
            for frame in 0..<inFrames { audio.channels[index][frame] *= Float(frame) / Float(inFrames) }
            for frame in 0..<outFrames { audio.channels[index][frames - 1 - frame] *= Float(frame) / Float(outFrames) }
        }
    }
    static func resample(_ audio: AudioSamples, to rate: Double) throws -> AudioSamples {
        guard rate != audio.sampleRate, audio.frameCount > 0 else { return audio }
        let count = AVAudioChannelCount(audio.channels.count)
        guard let input = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: count),
              let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: count),
              let converter = AVAudioConverter(from: input, to: output),
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(audio.frameCount)),
              let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(audio.frameCount) * rate / audio.sampleRate) + 1024) else { throw AppError.message("This sample rate conversion is unsupported.") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        source.frameLength = AVAudioFrameCount(audio.frameCount)
        for (index, channel) in audio.channels.enumerated() { channel.withUnsafeBufferPointer { source.floatChannelData![index].update(from: $0.baseAddress!, count: audio.frameCount) } }
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let pending = source
        var error: NSError?
        let status = converter.convert(to: target, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return pending
        }
        guard status != .error, let data = target.floatChannelData else { throw error ?? AppError.message("Sample rate conversion failed.") }
        let frames = Int(target.frameLength)
        return AudioSamples(channels: (0..<Int(count)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }, sampleRate: rate)
    }
    /// Integrated loudness per ITU-R BS.1770-4 with absolute and relative gating.
    static func integratedLoudness(_ audio: AudioSamples) -> Double {
        let rate = audio.sampleRate
        let weighted = audio.channels.map { kWeighted($0, rate: rate) }
        let block = Int(rate * 0.4), step = Int(rate * 0.1), frames = audio.frameCount
        var energies: [Double] = []
        if frames < block {
            energies = [weighted.reduce(0) { $0 + $1.reduce(0) { $0 + $1 * $1 } / Double(max(1, frames)) }]
        } else {
            var start = 0
            while start + block <= frames {
                energies.append(weighted.reduce(0) { total, channel in total + channel[start..<start + block].reduce(0) { $0 + $1 * $1 } / Double(block) })
                start += step
            }
        }
        func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(max(energy, 1e-12)) }
        let absolute = energies.filter { loudness($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let relative = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relative }
        return loudness(gated.reduce(0, +) / Double(max(1, gated.count)))
    }
    private static func kWeighted(_ samples: [Float], rate: Double) -> [Double] {
        // libebur128's derivation, which reproduces the BS.1770 48 kHz coefficients at any rate.
        func biquad(_ x: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count); var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let value = b[0] * x[i] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
                x2 = x1; x1 = x[i]; y2 = y1; y1 = value; y[i] = value
            }
            return y
        }
        var k = tan(Double.pi * 1681.974450955533 / rate), q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = biquad(samples.map(Double.init),
            [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
            [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
        k = tan(Double.pi * 38.13547087602444 / rate); q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        return biquad(shelf, [1, -2, 1], [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])
    }
    /// The gain for the chosen normalization. Loudness gain never pushes the peak above -1 dBFS.
    static func normalizationGain(_ audio: AudioSamples, mode: ExportNormalization) -> Float {
        let peak = Double(audio.peak)
        guard peak > 0 else { return 1 }
        let ceiling = pow(10, ExportOptions.peakCeiling / 20) / peak
        switch mode {
        case .off: return 1
        case .peak: return Float(ceiling)
        case .loudness:
            let loudness = integratedLoudness(audio)
            guard loudness.isFinite else { return 1 }
            return Float(min(pow(10, (ExportOptions.loudnessTarget - loudness) / 20), ceiling))
        }
    }
    static func render(_ source: URL, to destination: URL, options: ExportOptions) throws {
        if options.isPassthrough { try FileManager.default.copyItem(at: source, to: destination); return }
        var audio = try AudioSamples.read(source)
        if options.trimSilence { audio = trimSilence(audio) }
        if let rate = options.sampleRate { audio = try resample(audio, to: rate) }
        let gain = normalizationGain(audio, mode: options.normalization)
        if gain != 1 { audio.channels = audio.channels.map { $0.map { $0 * gain } } }
        try audio.writeWAV24(destination)
    }
}

@MainActor @Observable final class ExportSettings {
    var options: ExportOptions { didSet { if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: "exportOptions") } } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = defaults.data(forKey: "exportOptions").flatMap { try? JSONDecoder().decode(ExportOptions.self, from: $0) } ?? ExportOptions()
    }
}

struct ExportOptionsView: View {
    @Bindable var settings: ExportSettings
    var body: some View {
        Form {
            Picker("Normalize", selection: $settings.options.normalization) { ForEach(ExportNormalization.allCases) { Text($0.title).tag($0) } }
            Picker("Sample rate", selection: $settings.options.sampleRate) {
                Text("Original").tag(nil as Double?); Text("44.1 kHz").tag(44_100.0 as Double?); Text("48 kHz").tag(48_000.0 as Double?)
            }
            Toggle("Trim silence and add short fades", isOn: $settings.options.trimSilence)
            Text(settings.options.normalization == .loudness ? "WAV, 24-bit. Loudness never pushes peaks above −1 dBFS." : "WAV, 24-bit.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.columns).padding(.horizontal, 20).padding(.vertical, 12).frame(width: 380)
    }
}

/// Save and folder panels with export options as their accessory view.
@MainActor enum ExportPanel {
    static func run(_ files: [(source: URL, name: String)], settings: ExportSettings, completion: @escaping @MainActor (Error?) -> Void) {
        guard !files.isEmpty else { return }
        let accessory = NSHostingView(rootView: ExportOptionsView(settings: settings))
        accessory.frame.size = accessory.fittingSize
        func export(_ pairs: [(URL, URL)]) {
            let options = settings.options
            Task {
                do {
                    try await Task.detached {
                        for (source, target) in pairs {
                            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                            try AudioProcessing.render(source, to: target, options: options)
                        }
                    }.value
                    completion(nil)
                } catch { completion(error) }
            }
        }
        if files.count == 1 {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]; panel.canCreateDirectories = true
            panel.nameFieldStringValue = AudioFilename.safe(files[0].name) + ".wav"
            panel.accessoryView = accessory
            panel.begin { if $0 == .OK, let url = panel.url { export([(files[0].source, url)]) } }
        } else {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.prompt = "Export"; panel.message = "Choose a folder for these audio files."
            panel.accessoryView = accessory; panel.isAccessoryViewDisclosed = true
            panel.begin { result in
                guard result == .OK, let folder = panel.url else { return }
                export(files.map { file in
                    let base = folder.appendingPathComponent(AudioFilename.safe(file.name) + ".wav")
                    return (file.source, FileManager.default.fileExists(atPath: base.path) ? folder.appendingPathComponent(AudioFilename.safe(file.name) + " " + UUID().uuidString.prefix(8) + ".wav") : base)
                })
            }
        }
    }
}
