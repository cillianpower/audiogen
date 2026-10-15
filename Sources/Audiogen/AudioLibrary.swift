import Foundation
import AVFoundation
import Observation

struct WaveformData: Codable, Sendable { let duration: Double; let peaks: [Float] }
actor AudioFiles {
    func waveform(_ url: URL, cache: URL) throws -> WaveformData {
        if let bytes = try? Data(contentsOf: cache), let data = try? JSONDecoder().decode(WaveformData.self, from: bytes) { return data }
        let file = try AVAudioFile(forReading: url)
        let count = 1_200
        var peaks = [Float](repeating: 0, count: count)
        let length = file.length
        guard length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { throw AppError.message("This audio file is empty or unsupported.") }
        var position: Int64 = 0
        while position < length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                let bucket = min(count - 1, Int((position + Int64(frame)) * Int64(count) / length))
                for channel in 0..<Int(file.processingFormat.channelCount) { peaks[bucket] = max(peaks[bucket], abs(channels[channel][frame])) }
            }
            position += Int64(buffer.frameLength)
        }
        let data = WaveformData(duration: Double(length) / file.processingFormat.sampleRate, peaks: peaks)
        try JSONEncoder().encode(data).write(to: cache, options: .atomic)
        return data
    }
    func prepareGeneratedWAV(_ url: URL) throws {
        let source = try AVAudioFile(forReading: url)
        if source.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24,
           source.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool != true { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writePCM24(source, to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
    private func writePCM24(_ source: AVAudioFile, to output: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: source.processingFormat.sampleRate, AVNumberOfChannelsKey: source.processingFormat.channelCount, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let destination = try AVAudioFile(forWriting: output, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_384) else { throw AppError.message("This audio format could not be converted.") }
        while source.framePosition < source.length { try Task.checkCancellation(); try source.read(into: buffer); try destination.write(from: buffer) }
    }
    static let acceptedExtensions = ["wav", "aiff", "aif", "flac", "mp3", "m4a"]
    /// Copies audio into the library folder. WAV is copied unchanged, so float bounces keep
    /// their headroom; other formats become 24-bit WAV. Unreadable files are removed again.
    func importToLibrary(_ url: URL, folder: URL, id: UUID) throws -> URL {
        guard Self.acceptedExtensions.contains(url.pathExtension.lowercased()) else { throw AppError.message("Choose a WAV, AIFF, FLAC, MP3 or M4A audio file.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = AudioFilename.safe(url.deletingPathExtension().lastPathComponent)
        var target = folder.appendingPathComponent(stem + ".wav")
        if FileManager.default.fileExists(atPath: target.path) { target = folder.appendingPathComponent(stem + " " + id.uuidString.prefix(8) + ".wav") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            if url.pathExtension.lowercased() == "wav" { try FileManager.default.copyItem(at: url, to: target) }
            else { try writePCM24(try AVAudioFile(forReading: url), to: target) }
            guard try AVAudioFile(forReading: target).length > 0 else { throw AppError.message("This audio file is empty.") }
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        return target
    }
    func importReference(_ url: URL, directory: URL) throws -> URL {
        guard Self.acceptedExtensions.contains(url.pathExtension.lowercased()) else { throw AppError.message("Choose a WAV, AIFF, FLAC, MP3 or M4A audio file.") }
        let folder = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent(url.lastPathComponent)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: original)
        if url.pathExtension.lowercased() == "wav" { return original }
        let source = try AVAudioFile(forReading: original)
        let output = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".wav")
        try writePCM24(source, to: output)
        return output
    }
}
@MainActor @Observable final class AudioPlayer {
    var peaks: [Float] = []
    var duration: Double = 0
    var time: Double = 0
    var isPlaying = false
    var loop = false
    var selection: AudioRegion?
    var volume: Float = 0.8 { didSet { player?.volume = volume } }
    var url: URL?
    var loading = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private let files = AudioFiles()
    var error: String?
    func load(_ url: URL?, cache: URL?, at position: Double = 0, autoplay: Bool = false) {
        loadTask?.cancel(); player?.stop(); timer?.invalidate()
        player = nil; isPlaying = false; time = 0; duration = 0; peaks = []; selection = nil; self.url = url; error = nil
        guard let url, let cache else { loading = false; return }
        loading = true
        loadTask = Task { [self] in
            do {
                let waveform = try await files.waveform(url, cache: cache)
                try Task.checkCancellation()
                let audio = try AVAudioPlayer(contentsOf: url)
                audio.volume = volume
                audio.prepareToPlay()
                player = audio; duration = waveform.duration; peaks = waveform.peaks; loading = false
                seek(position)
                if autoplay { audio.play(); isPlaying = audio.isPlaying }
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch is CancellationError {} catch { loading = false; self.error = "This audio could not be opened. \(error.localizedDescription)" }
        }
    }
    private func tick() {
        guard let player else { return }
        if isPlaying, loop, let region = selection, player.currentTime >= region.end || !player.isPlaying {
            player.currentTime = region.start; player.play()
        } else if isPlaying, loop, selection == nil, !player.isPlaying { player.currentTime = 0; player.play() }
        isPlaying = player.isPlaying; time = player.currentTime
    }
    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause() }
        else {
            if loop, let selection, player.currentTime < selection.start || player.currentTime >= selection.end { player.currentTime = selection.start }
            if player.currentTime >= duration - 0.02 { player.currentTime = 0 }
            player.play()
        }
        isPlaying = player.isPlaying
    }
    func seek(_ value: Double) { time = min(duration, max(0, value)); player?.currentTime = time }
}
actor LibraryPersistence {
    let paths: AppPaths
    init(paths: AppPaths) { self.paths = paths }
    func load() throws -> [Generation] {
        try paths.prepare()
        let files = try FileManager.default.contentsOfDirectory(at: paths.metadata, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try files.map { url in
            var generation = try decoder.decode(Generation.self, from: Data(contentsOf: url))
            if generation.state == .generating || generation.state == .waiting { generation.state = .failed; generation.error = "The app closed before this generation finished. Duplicate its settings to try again." }
            return generation
        }.sorted { $0.created > $1.created }
    }
    func save(_ generation: Generation) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(generation).write(to: paths.metadata.appendingPathComponent(generation.id.uuidString + ".json"), options: .atomic)
    }
    func rename(_ id: UUID, name: String, in generations: [Generation]) throws -> [Generation] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = generations.firstIndex(where: { $0.id == id }) else { throw AppError.message("Enter a name for this generation.") }
        var updated = generations
        let original = generations[index]
        var moved: (URL, URL)?
        if let source = original.audio {
            let target = AudioFilename.renamed(source, name: name, id: id)
            if source != target {
                try FileManager.default.moveItem(at: source, to: target)
                moved = (source, target); updated[index].audio = target
                for other in updated.indices {
                    if updated[other].request.source == source { updated[other].request.source = target }
                    if updated[other].request.reference == source { updated[other].request.reference = target }
                }
            }
        }
        updated[index].name = name
        let changed = updated.indices.filter { i in
            i == index || updated[i].request.source != generations[i].request.source || updated[i].request.reference != generations[i].request.reference
        }
        do { for i in changed { try save(updated[i]) } }
        catch {
            if let (source, target) = moved { try? FileManager.default.moveItem(at: target, to: source) }
            for i in changed { try? save(generations[i]) }
            throw error
        }
        return updated
    }
    func delete(_ generation: Generation) throws {
        // Plain WAV files stay on disk so a dragged Ableton clip never loses its source.
        try FileManager.default.removeItem(at: paths.metadata.appendingPathComponent(generation.id.uuidString + ".json"))
    }
}
/// Selected regions dragged out of a waveform. Clips are kept in a `Clips` folder beside their
/// source, because DAWs such as Ableton reference dragged files where they are.
enum AudioClips {
    static func clip(of source: URL, region: AudioRegion) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let rate = input.processingFormat.sampleRate
        let start = max(0, AVAudioFramePosition((region.start * rate).rounded()))
        let end = min(input.length, AVAudioFramePosition((region.end * rate).rounded()))
        guard end > start else { throw AppError.message("Select a longer region to drag.") }
        let folder = source.deletingLastPathComponent().appendingPathComponent("Clips")
        let target = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + String(format: " %.2f-%.2fs.wav", region.start, region.end))
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent("." + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(end - start)) else { throw AppError.message("This region could not be read.") }
        input.framePosition = start
        try input.read(into: buffer, frameCount: AVAudioFrameCount(end - start))
        do {
            // Keep the source's sample format, so the clip has exactly the source's samples.
            let output = try AVAudioFile(forWriting: temporary, settings: input.fileFormat.settings, commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
            try output.write(from: buffer)
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
    /// The selection as a clip when there is one, otherwise the whole file.
    @MainActor static func dragFile(for player: AudioPlayer) throws -> URL? {
        guard let url = player.url else { return nil }
        if let region = player.selection, region.duration > 0.01 { return try clip(of: url, region: region) }
        return url
    }
}
func clockText(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60) }

struct AudioFilename {
    static func safe(_ name: String) -> String {
        var value = name.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while value.utf8.count > 180 { value.removeLast() }
        return value.isEmpty ? "Audio" : value
    }
    static func renamed(_ source: URL, name: String, id: UUID) -> URL {
        let stem = safe(name)
        let folder = source.deletingLastPathComponent()
        var target = folder.appendingPathComponent(stem).appendingPathExtension(source.pathExtension)
        var counter = 0
        while target != source && FileManager.default.fileExists(atPath: target.path) {
            counter += 1
            let suffix = String(id.uuidString.prefix(8)) + (counter > 1 ? "-\(counter)" : "")
            target = folder.appendingPathComponent("\(stem) \(suffix)").appendingPathExtension(source.pathExtension)
        }
        return target
    }
}
