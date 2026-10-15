import XCTest
import Foundation
@testable import Audiogen

private final class FixtureResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var requests: [URLRequest] = []
    func set(_ values: [String: String]) { lock.withLock { self.values = values; requests = [] } }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func recorded() -> [URLRequest] { lock.withLock { requests } }
    func get(_ path: String) -> String? { lock.withLock { values[path] } }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let responses = FixtureResponses()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.responses.record(captured)
        guard let url = request.url, let fixture = Self.responses.get(url.path) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class ACEContractTests: XCTestCase {
    private func engine() throws -> ACEEngine {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return ACEEngine(paths: .standard, manifest: try .bundled(), session: URLSession(configuration: config))
    }
    func testHealthRequiresLoadedCompatibleModel() async throws {
        let engine = try engine()
        FixtureProtocol.responses.set(["/health": #"{"code":200,"data":{"service":"ACE-Step API","status":"ok","models_initialized":true}}"#, "/v1/models": #"{"code":200,"data":{"models":[{"name":"acestep-v15-turbo"}]}}"#])
        let ready = await engine.health(); XCTAssertTrue(ready)
        FixtureProtocol.responses.set(["/health": #"{"code":200,"data":{"service":"unrelated","status":"ok"}}"#])
        let wrong = await engine.health(); XCTAssertFalse(wrong)
    }
    func testPinnedRuntimeOpenAIModelInventory() async throws {
        let engine = try engine()
        FixtureProtocol.responses.set(["/health": #"{"code":200,"data":{"service":"ACE-Step API","status":"ok","models_initialized":true}}"#, "/v1/models": #"{"object":"list","data":[{"id":"acestep/acestep-v15-turbo","name":"ACE-Step acestep-v15-turbo"}]}"#])
        let ready = await engine.health(); XCTAssertTrue(ready)
    }
    func testReadinessUsesSelectedCheckpoint() async throws {
        let engine = try engine(); engine.modelID = "acestep-v15-xl-sft"
        FixtureProtocol.responses.set(["/health": #"{"code":200,"data":{"service":"ACE-Step API","status":"ok","models_initialized":true}}"#, "/v1/models": #"{"object":"list","data":[{"id":"acestep/acestep-v15-turbo"}]}"#])
        let wrong = await engine.health(); XCTAssertFalse(wrong)
        FixtureProtocol.responses.set(["/health": #"{"code":200,"data":{"service":"ACE-Step API","status":"ok","models_initialized":true}}"#, "/v1/models": #"{"object":"list","data":[{"id":"acestep/acestep-v15-xl-sft"}]}"#])
        let ready = await engine.health(); XCTAssertTrue(ready)
    }
    func testUnloadedCheckpointAndWrongPrimaryAreNotReady() async throws {
        let engine = try engine(); engine.modelID = "acestep-v15-sft"
        let health = #"{"code":200,"data":{"service":"ACE-Step API","status":"ok","models_initialized":true}}"#
        FixtureProtocol.responses.set(["/health": health, "/v1/models": #"{"code":200,"data":{"default_model":"acestep-v15-sft","models":[{"name":"acestep-v15-sft","is_loaded":false}]}}"#])
        let unloaded = await engine.health(); XCTAssertFalse(unloaded)
        FixtureProtocol.responses.set(["/health": health, "/v1/models": #"{"code":200,"data":{"default_model":"acestep-v15-turbo","models":[{"name":"acestep-v15-sft","is_loaded":true}]}}"#])
        let secondary = await engine.health(); XCTAssertFalse(secondary)
    }
    func testAdapterConfigurationAndMissingFileFailure() async throws {
        let engine = try engine()
        FixtureProtocol.responses.set(["/v1/lora/unload": #"{"code":200,"data":{"message":"unloaded"}}"#, "/v1/lora/load": #"{"code":200,"data":{"message":"loaded"}}"#, "/v1/lora/scale": #"{"code":200,"data":{"scale":0.5}}"#])
        var request = GenerationRequest()
        try await engine.configureLoRA(request)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        request.lora = folder; request.loraScale = 0.5
        try await engine.configureLoRA(request)
        let calls = FixtureProtocol.responses.recorded()
        XCTAssertEqual(calls.map { $0.url!.path }, ["/v1/lora/unload", "/v1/lora/unload", "/v1/lora/load", "/v1/lora/scale"])
        XCTAssertTrue(calls.allSatisfy { $0.httpMethod == "POST" })
        let load = try XCTUnwrap(calls[2].httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: load) as? [String: Any])
        XCTAssertEqual(payload["lora_path"] as? String, folder.path)
        let scale = try XCTUnwrap(calls[3].httpBody)
        let scalePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: scale) as? [String: Any])
        XCTAssertEqual(scalePayload["scale"] as? Double, 0.5)
        request.lora = folder.appendingPathComponent("missing")
        do { try await engine.configureLoRA(request); XCTFail("Missing adapter should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("could not be found")) }
    }
    func testAsyncTaskAndJSONStringResultContract() async throws {
        let engine = try engine()
        let output = #"[{"file":"/v1/audio?path=%2Ftmp%2Fresult.wav","seed_value":"42"}]"#
        let result = try JSONSerialization.data(withJSONObject: ["code": 200, "data": [["task_id": "job-1", "status": 1, "result": output]]])
        FixtureProtocol.responses.set(["/release_task": #"{"code":200,"data":{"task_id":"job-1","status":"queued"}}"#, "/query_result": String(decoding: result, as: UTF8.self)])
        var request = GenerationRequest(); request.prompt = "texture"
        let job = try await engine.generate(request)
        XCTAssertEqual(job.id, "job-1")
        let audio = try await engine.result(job)
        XCTAssertEqual(audio?.file.host, "127.0.0.1")
        XCTAssertEqual(audio?.file.port, 8001)
        XCTAssertEqual(audio?.metadata, output)
    }
    func testRejectsResultOutsideLoopback() async throws {
        let engine = try engine()
        let output = #"[{"file":"https://example.com/audio.wav"}]"#
        let result = try JSONSerialization.data(withJSONObject: ["code": 200, "data": [["task_id": "job-1", "status": 1, "result": output]]])
        FixtureProtocol.responses.set(["/query_result": String(decoding: result, as: UTF8.self)])
        do { _ = try await engine.result(GenerationJob(id: "job-1")); XCTFail("Remote results must be rejected") } catch { XCTAssertTrue(error.localizedDescription.contains("invalid audio")) }
    }
    func testQueuedTaskReturnsNoResult() async throws {
        FixtureProtocol.responses.set(["/query_result": #"{"code":200,"data":[{"task_id":"job-1","status":0}]}"#])
        let value = try await engine().result(GenerationJob(id: "job-1")); XCTAssertNil(value)
    }
}
