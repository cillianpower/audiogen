import XCTest
import Foundation
@testable import Audiogen

final class GenerationPlanTests: XCTestCase {
    func testBothEnginesSharePromptAndSeedButKeepModelSettings() throws {
        var request = GenerationRequest()
        request.prompt = "An evolving ambient texture"; request.seed = 123; request.steps = 50
        request.reference = URL(fileURLWithPath: "/reference.wav")
        request.lora = URL(fileURLWithPath: "/adapter"); request.loraScale = 0.4
        let plan = GenerationPlan.requests(base: request, selected: .ace, both: true, aceModel: .sft, miniMaxModel: "efficient", miniMaxSteps: 20)
        XCTAssertEqual(plan.map { $0.0 }, [.ace, .miniMax])
        XCTAssertEqual(plan.map { $0.1.prompt }, [request.prompt, request.prompt])
        XCTAssertEqual(plan.map { $0.1.seed }, [123, 123])
        XCTAssertEqual(plan.map { $0.1.model }, ["acestep-v15-sft", "efficient"])
        XCTAssertEqual(plan.map { $0.1.steps }, [50, 20])
        XCTAssertEqual(plan[0].1.reference, request.reference)
        XCTAssertEqual(plan[0].1.loraScale, 0.4)
        XCTAssertNil(plan[1].1.reference); XCTAssertNil(plan[1].1.lora)
    }
    func testMiniMaxFirstAndXLDefaults() {
        var request = GenerationRequest(); request.steps = 30
        let plan = GenerationPlan.requests(base: request, selected: .miniMax, both: true, aceModel: .xlSFT, miniMaxModel: "balanced", miniMaxSteps: 20)
        XCTAssertEqual(plan.map { $0.0 }, [.miniMax, .ace])
        XCTAssertEqual(plan.map { $0.1.steps }, [30, 50])
        XCTAssertEqual(plan[1].1.model, "acestep-v15-xl-sft")
    }
    func testSingleEngineRepaintKeepsSourceRegion() {
        var request = GenerationRequest(); request.mode = .repaint
        request.source = URL(fileURLWithPath: "/source.wav"); request.region = AudioRegion(start: 2, end: 4)
        let plan = GenerationPlan.requests(base: request, selected: .ace, both: false, aceModel: .turbo, miniMaxModel: "efficient", miniMaxSteps: 20)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].1.region, request.region); XCTAssertEqual(plan[0].1.source, request.source)
        XCTAssertEqual(plan[0].1.mode, .repaint)
    }
    func testOldRequestDecodesWithoutAdapterFields() throws {
        let old = GenerationRequest()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "lora"); json.removeValue(forKey: "loraScale")
        let request = try JSONDecoder().decode(GenerationRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(request.lora); XCTAssertNil(request.loraScale)
    }
    func testCheckpointImportPreservesExistingModelsAndRejectsIncompleteFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("download"); let destination = root.appendingPathComponent("models/sft")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try ACECheckpointImporter.copy(source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try Data("weights".utf8).write(to: source.appendingPathComponent("model.safetensors"))
        try ACECheckpointImporter.copy(source, to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertThrowsError(try ACECheckpointImporter.copy(source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("model.safetensors")), Data("weights".utf8))
    }
}
