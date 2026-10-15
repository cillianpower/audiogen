import Foundation
import Observation

@MainActor @Observable final class RuntimeDownload: Identifiable {
    enum State { case queued, running, complete, interrupted }
    let id: String
    let engine: EngineID
    let model: String
    var state: State = .queued
    var status = "Waiting for another download"
    var progress: Double?
    var error: String?
    var active: Bool { state == .queued || state == .running }
    init(engine: EngineID, model: String) { self.engine = engine; self.model = model; id = "\(engine.rawValue)/\(model)" }
}

/// One install at a time per engine avoids racing shared files. Engines download
/// independently of one another and independently of the generation queue.
@MainActor @Observable final class RuntimeDownloads {
    var records: [String: RuntimeDownload] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tails: [EngineID: Task<Void, Never>] = [:]
    func record(_ engine: EngineID, model: String) -> RuntimeDownload? { records["\(engine.rawValue)/\(model)"] }
    func active(_ engine: EngineID) -> Bool { records.values.contains { $0.engine == engine && $0.active } }
    func enqueue(engine: EngineID, model: String, operation: @escaping @MainActor (@escaping @MainActor (String, Double?) -> Void) async throws -> Void) {
        let record = RuntimeDownload(engine: engine, model: model)
        guard records[record.id]?.active != true else { return }
        records[record.id] = record
        let previous = tails[engine]
        let task = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                record.state = .running; record.status = "Preparing download"
                try await operation { status, progress in
                    guard record.active else { return }
                    record.status = status; record.progress = progress
                }
                try Task.checkCancellation()
                record.state = .complete; record.status = "Installed"; record.progress = 1
            } catch {
                record.state = .interrupted; record.progress = nil
                record.error = Task.isCancelled || error is CancellationError ? nil : error.localizedDescription
                record.status = Task.isCancelled ? "Paused · Resume when ready" : "Interrupted · Resume to retry"
            }
            if records[record.id] === record { tasks[record.id] = nil }
        }
        tasks[record.id] = task; tails[engine] = task
    }
    func cancel(_ engine: EngineID, model: String) {
        let id = "\(engine.rawValue)/\(model)"
        tasks[id]?.cancel()
        if let record = records[id], record.state == .queued { record.state = .interrupted; record.status = "Paused · Resume when ready" }
    }
    func cancelAll() { for task in tasks.values { task.cancel() } }
    func finish() async { let pending = Array(tasks.values); for task in pending { await task.value } }
}
