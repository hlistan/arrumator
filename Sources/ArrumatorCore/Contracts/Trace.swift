import Foundation

public enum TraceStage: String, Sendable, Codable, CaseIterable {
    case hash, dedupe, extract, ocr, vlm, entities, analyse, consolidate, embed, name, place, index
    /// A new document was given the tags its file was queued with (`GivenTag`), as the user's rules write them: which
    /// folder in Incoming or command gave each.
    case tag
    /// The model read a search task's prompt into a plan.
    case interpret
    /// The documents a search task's plan asks for were found.
    case match

    /// The step records what the document says: prompts holding its text, the model's answers drawn from it, or the
    /// labels made of those answers. Reading a task's prompt shows the model the archive's labels, drawn from them.
    public var holdsDocumentContent: Bool { [.analyse, .vlm, .consolidate, .interpret].contains(self) }

    /// The step talked to a model, and keeps the prompts and raw answers under `TraceStep.exchangeKey` of its output.
    public var exchangesWithModel: Bool { [.analyse, .vlm, .interpret].contains(self) }
}

public enum TraceStatus: String, Sendable, Codable, Comparable {
    case skipped, ok, warn, error

    /// `error` is worse than `warn`, worse than `ok`, worse than `skipped`.
    public static func < (lhs: TraceStatus, rhs: TraceStatus) -> Bool {
        let order: [TraceStatus] = [.skipped, .ok, .warn, .error]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

public enum TraceSource: String, Sendable, Codable {
    case ingest, eval, replay, cli
    /// A search task's prompt was read and its documents found.
    case task
}

/// One recorded pipeline step. Payloads are JSON strings so any Encodable can be stored.
public struct TraceStep: Sendable, Codable {
    /// The key of a step's output under which a step that talked to a model keeps what was sent and what came back:
    /// the part retention clears, leaving what the step concluded.
    public static let exchangeKey = "exchange"

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
                             durationMs: startedAt.milliseconds(until: Date()),
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
                                     durationMs: start.milliseconds(until: Date()), input: inputJSON,
                                     output: output(value).map { JSON.string($0) })
                await record(step)
            }
            return value
        } catch {
            if isEnabled {
                await record(TraceStep(stage: stage, status: .error, startedAt: start,
                                       durationMs: start.milliseconds(until: Date()), input: inputJSON,
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
