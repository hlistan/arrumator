import Foundation

public enum TraceStage: String, Sendable, Codable, CaseIterable {
    case stability, hash, dedupe, extract, ocr, vlm, entities, correspondent, rules, embed, candidates
    case llm, judge, validate, calibrate, name, place, index, learn, review, undo
}

public enum TraceStatus: String, Sendable, Codable {
    case ok, warn, error, skipped
}

public enum TraceSource: String, Sendable, Codable {
    case ingest, eval, replay, review, cli, rethink
}

/// One recorded pipeline step. Payloads are JSON strings so any Encodable can be stored.
public struct TraceStep: Sendable, Codable {
    public var stage: TraceStage
    public var status: TraceStatus
    public var startedAt: Date
    public var durationMs: Double
    public var input: String?
    public var output: String?
    public var error: String?

    public init(stage: TraceStage, status: TraceStatus = .ok, startedAt: Date = Date(), durationMs: Double = 0,
                input: String? = nil, output: String? = nil, error: String? = nil) {
        self.stage = stage
        self.status = status
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.input = input
        self.output = output
        self.error = error
    }
}

/// Destination for trace steps. `TraceRecorder` (DB) implements it; tests can collect in memory.
public protocol TraceSink: Sendable {
    func append(traceID: Int64, step: TraceStep) async
}

/// Handle passed through the pipeline so every stage can record what it did.
public struct TraceContext: Sendable {
    public let traceID: Int64?
    public let sink: (any TraceSink)?

    public init(traceID: Int64?, sink: (any TraceSink)?) {
        self.traceID = traceID
        self.sink = sink
    }

    public static let disabled = TraceContext(traceID: nil, sink: nil)

    public var isEnabled: Bool { traceID != nil && sink != nil }

    public func record(_ step: TraceStep) async {
        guard let traceID, let sink else { return }
        await sink.append(traceID: traceID, step: step)
    }

    public func record(_ stage: TraceStage, status: TraceStatus = .ok, startedAt: Date, input: (any Encodable)? = nil,
                       output: (any Encodable)? = nil, error: String? = nil) async {
        guard isEnabled else { return }
        let step = TraceStep(stage: stage, status: status, startedAt: startedAt,
                             durationMs: Date().timeIntervalSince(startedAt) * 1000,
                             input: input.map { JSON.string($0) }, output: output.map { JSON.string($0) }, error: error)
        await record(step)
    }

    // periphery:ignore:parameters isolation - read by the compiler, which runs the body on that actor
    /// Runs `body`, recording duration, output and errors as one step.
    /// Runs on the caller's isolation, so `body` may touch the caller's actor state.
    public func measure<T>(_ stage: TraceStage, input: (any Encodable)? = nil,
                           output: (T) -> (any Encodable)? = { _ in nil },
                           status: (T) -> TraceStatus = { _ in .ok },
                           isolation: isolated (any Actor)? = #isolation,
                           _ body: () async throws -> T) async rethrows -> T {
        let start = Date()
        let inputJSON = isEnabled ? input.map { JSON.string($0) } : nil
        do {
            let value = try await body()
            if isEnabled {
                let step = TraceStep(stage: stage, status: status(value), startedAt: start,
                                     durationMs: Date().timeIntervalSince(start) * 1000, input: inputJSON,
                                     output: output(value).map { JSON.string($0) })
                await record(step)
            }
            return value
        } catch {
            if isEnabled {
                await record(TraceStep(stage: stage, status: .error, startedAt: start,
                                       durationMs: Date().timeIntervalSince(start) * 1000, input: inputJSON,
                                       error: String(describing: error)))
            }
            throw error
        }
    }
}

/// In-memory sink, handy for the CLI and tests.
public actor MemoryTraceSink: TraceSink {
    public private(set) var steps: [TraceStep] = []
    public init() {}
    public func append(traceID: Int64, step: TraceStep) async { steps.append(step) }
}
