import XCTest
import Foundation
import AVFoundation
import AppKit
import SwiftUI
@testable import Audiogen

private final class MiniMaxFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func set(_ value: [String: Data]) { lock.withLock { data = value } }
    func get(_ key: String) -> Data? { lock.withLock { data[key] } }
}
private final class MiniMaxProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = MiniMaxFixtures()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let bytes = Self.fixtures.get(url.path) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class MiniMaxTests: XCTestCase {
    func testServerContractRequiresPinnedRuntimeAndCompleteModelSet() async throws {
        let manifest = try MiniMaxManifest.bundled()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MiniMaxProtocol.self]
        let engine = MiniMaxEngine(paths: .standard, manifest: manifest, session: URLSession(configuration: config))
        let inventory = Dictionary(uniqueKeysWithValues: zip(["lm", "depth", "cond", "dit", "vae"], manifest.presets[0].models).map { ($0.0, [$0.1.name]) })
        MiniMaxProtocol.fixtures.set([
            "/health": Data(#"{"status":"ok"}"#.utf8),
            "/props": try JSONSerialization.data(withJSONObject: ["version": "3eef713 (2026-09-28)", "models": inventory]),
            "/job": Data(#"{"status":"running"}"#.utf8)
        ])
        let healthy = await engine.health(); XCTAssertTrue(healthy)
        let pending = try await engine.result(GenerationJob(id: "abc")); XCTAssertNil(pending)
        try await engine.cancel(GenerationJob(id: "abc"))
        MiniMaxProtocol.fixtures.set([
            "/health": Data(#"{"status":"ok"}"#.utf8),
            "/props": try JSONSerialization.data(withJSONObject: ["version": "another-runtime", "models": inventory])
        ])
        let incompatible = await engine.health(); XCTAssertFalse(incompatible)
    }

    func testHostedPromptEditorPublishesNativeEdits() async throws {
        var value = ""
        let host = NSHostingView(rootView: PromptEditor(text: Binding(get: { value }, set: { value = $0 }), history: { _ in }, focusChanged: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        host.layoutSubtreeIfNeeded()
        func findEditor(_ view: NSView) -> HistoryTextView? {
            if let editor = view as? HistoryTextView { return editor }
            for child in view.subviews { if let editor = findEditor(child) { return editor } }
            return nil
        }
        var editor = findEditor(host)
        for _ in 0..<20 {
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded(); editor = findEditor(host)
        }
        let input = try XCTUnwrap(editor)
        input.insertText("bowed metal texture", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(value, "bowed metal texture")
        input.insertText(" with long decays", replacementRange: NSRange(location: input.string.utf16.count, length: 0))
        XCTAssertEqual(value, "bowed metal texture with long decays")
    }
    func testPromptSelectionSurvivesUpdatesAndUsesVisibleDocumentBounds() async throws {
        var value = "A slowly evolving ambient pad with gentle harmonics"
        let editorView = { PromptEditor(text: Binding(get: { value }, set: { value = $0 }), history: { _ in }, focusChanged: { _ in }) }
        let host = NSHostingView(rootView: editorView())
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func find(_ view: NSView) -> HistoryTextView? {
            if let input = view as? HistoryTextView { return input }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        var input: HistoryTextView?
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); input = find(host); if input != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let text = try XCTUnwrap(input)
        XCTAssertTrue(window.makeFirstResponder(text))
        let selection = NSRange(location: 9, length: 16)
        text.setSelectedRange(selection)
        host.rootView = editorView(); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(text.selectedRange(), selection)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        // The editor is transparent so the composer's Liquid Glass shows through; text keeps the system colour.
        XCTAssertFalse(text.drawsBackground); XCTAssertFalse(scroll.drawsBackground)
        XCTAssertEqual(text.textColor, .textColor)
        XCTAssertGreaterThanOrEqual(text.bounds.height, scroll.contentSize.height)
        XCTAssertNotNil(text.layoutManager)
        host.frame.size.width = 320; host.layoutSubtreeIfNeeded()
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertGreaterThan(text.bounds.width, 0)
        if let snapshot = ProcessInfo.processInfo.environment["AUDIOGEN_PROMPT_SNAPSHOT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: snapshot))
        }
        text.insertText("changing texture", replacementRange: selection)
        XCTAssertEqual(value, "A slowly changing texture pad with gentle harmonics")
    }
    func testInstallationMarkerIgnoresJSONKeyOrdering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MiniMaxEngine(paths: AppPaths(support: root, logs: root.appendingPathComponent("logs")), manifest: try .bundled())
        try FileManager.default.createDirectory(at: engine.binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine.models, withIntermediateDirectories: true)
        try Data().write(to: engine.binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.binary.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(engine.preset).write(to: engine.directory.appendingPathComponent("efficient.json"))
        try encoder.encode(MiniMaxEngine.Runtime(sourceRevision: engine.manifest.sourceRevision, ggmlRevision: engine.manifest.ggmlRevision, sha256: String(repeating: "0", count: 64))).write(to: engine.binary.deletingLastPathComponent().appendingPathComponent("runtime.json"))
        for artifact in engine.preset.models { try Data().write(to: engine.models.appendingPathComponent(artifact.name)) }
        XCTAssertTrue(engine.installed)
        try FileManager.default.removeItem(at: engine.models.appendingPathComponent(engine.preset.models[0].name))
        XCTAssertFalse(engine.installed)
    }
    func testPinnedModelsAndRouting() throws {
        let manifest = try MiniMaxManifest.bundled()
        XCTAssertEqual(manifest.sourceRevision.count, 40)
        XCTAssertEqual(manifest.modelRevision.count, 40)
        for preset in manifest.presets {
            XCTAssertEqual(preset.models.count, 5)
            for file in preset.models {
                XCTAssertEqual(file.sha256.count, 64)
                XCTAssertTrue(file.url.path.contains(manifest.modelRevision))
                XCTAssertGreaterThan(file.bytes, 0)
            }
            var request = GenerationRequest(); request.prompt = "bowed metal"; request.model = preset.id; request.steps = 30; request.seed = 42; request.noPercussion = true
            let body = try MiniMaxEngine.payload(request, preset: preset)
            XCTAssertEqual(body["output_format"] as? String, "wav24")
            XCTAssertEqual(body["lm_seed"] as? Int64, 42)
            XCTAssertEqual(body["seed"] as? Int64, 42)
            XCTAssertEqual(body["lm_model"] as? String, preset.models[0].name)
            XCTAssertEqual(body["lyrics"] as? String, "[instrumental]")
            XCTAssertTrue((body["caption"] as? String)?.contains("No drums") == true)
            XCTAssertEqual(request.prompt, "bowed metal")
            request.mode = .repaint
            XCTAssertThrowsError(try MiniMaxEngine.payload(request, preset: preset))
        }
    }
    func testBinaryMultipartDoesNotDecodeWAVAsText() throws {
        let wav = Data("RIFF".utf8) + Data([0, 255, 128, 13, 10, 0, 1])
        var body = Data("--fixture\r\nContent-Type: application/json\r\n\r\n{\"seed\":42}\r\n--fixture\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(wav); body.append(Data("\r\n--fixture--\r\n".utf8))
        let result = try MiniMaxEngine.decodeResult(body, contentType: "multipart/mixed; boundary=fixture")
        XCTAssertEqual(result.audio, wav)
        XCTAssertEqual(result.metadata, #"{"seed":42}"#)
        XCTAssertThrowsError(try MiniMaxEngine.decodeResult(body.dropLast(30), contentType: "multipart/mixed; boundary=fixture"))
        XCTAssertThrowsError(try MiniMaxEngine.decodeResult(body, contentType: "audio/mpeg"))
    }
    func testLiveInstallAndGenerate() async throws {
        guard ProcessInfo.processInfo.environment["AUDIOGEN_TEST_MINIMAX"] == "1" else { throw XCTSkip("Opt-in real MiniMax model download and Metal inference") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/minimax-smoke")
        let paths = AppPaths(support: root, logs: root.appendingPathComponent("Logs"))
        let engine = MiniMaxEngine(paths: paths, manifest: try .bundled())
        do {
            try await engine.install { status, fraction in print("MINIMAX \(status) \(Int((fraction ?? 0) * 100))%") }
            try await engine.start()
            let healthy = await engine.health(); XCTAssertTrue(healthy)
            var request = GenerationRequest(); request.prompt = "A sustained bowed metal drone, atmospheric resonances, slowly evolving harmonics. Instrumental ambient sound texture, no rhythmic pulse."
            request.duration = 10; request.seed = 42; request.steps = 2; request.model = "efficient"; request.noPercussion = true
            let job = try await engine.generate(request)
            var output: EngineResult?
            for _ in 0..<1200 {
                output = try await engine.result(job)
                if output != nil { break }
                try await Task.sleep(for: .seconds(2))
            }
            guard let output else { throw AppError.message("MiniMax render timed out") }
            let target = root.appendingPathComponent("smoke.wav")
            try? FileManager.default.removeItem(at: target)
            try await engine.download(output, to: target)
            let file = try AVAudioFile(forReading: target)
            XCTAssertEqual(file.fileFormat.sampleRate, 44100)
            XCTAssertEqual(file.fileFormat.channelCount, 2)
            XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
            XCTAssertGreaterThan(file.length, 0)
            print("MINIMAX OUTPUT \(target.path) frames=\(file.length)")
            let cancelled = try await engine.generate(request)
            try await engine.cancel(cancelled)
            await engine.stop()
            XCTAssertFalse(engine.ownsServer)
        } catch { await engine.stop(); throw error }
    }
}

final class CodeSignatureTests: XCTestCase {
    func testSignedBinaryPassesAndAlteredOrUnsignedFails() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let signed = folder.appendingPathComponent("tool"), altered = folder.appendingPathComponent("altered"), unsigned = folder.appendingPathComponent("plain")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: signed)
        XCTAssertTrue(CodeSignature.isValid(signed))
        var bytes = try Data(contentsOf: signed); bytes[bytes.count / 2] ^= 0xFF; try bytes.write(to: altered)
        XCTAssertFalse(CodeSignature.isValid(altered))
        try Data("#!/bin/sh\n".utf8).write(to: unsigned)
        XCTAssertFalse(CodeSignature.isValid(unsigned))
    }
}
