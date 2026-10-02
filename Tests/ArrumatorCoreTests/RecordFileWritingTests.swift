@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// Writing a record file from the index never writes over what reached the file after it was read, and two writings
/// never overlap (docs/storage.md): what a test does between reading a file and writing it (`setBeforeWriting`) is what
/// the user or another process could do at that moment.
@Suite struct RecordFileWritingTests {
    /// What a flush is held at, between reading a file and writing it: how many times it got there, and a gate the
    /// first time waits at until the test opens it.
    private final class Hold: Sendable {
        private let state = Mutex<(arrivals: Int, gate: CheckedContinuation<Void, Never>?, open: Bool)>((0, nil, false))

        var arrivals: Int { state.withLock { $0.arrivals } }

        /// Arrives; the first arrival waits until `open()`.
        func arrive() async {
            let first = state.withLock { state in
                state.arrivals += 1
                return state.arrivals == 1
            }
            guard first else { return }
            await withCheckedContinuation { continuation in
                let open = state.withLock { state in
                    if !state.open { state.gate = continuation }
                    return state.open
                }
                if open { continuation.resume() }
            }
        }

        func open() {
            let gate = state.withLock { state in
                state.open = true
                defer { state.gate = nil }
                return state.gate
            }
            gate?.resume()
        }
    }

    /// Runs `change` the first time a flush is between reading the file at `url` and writing it.
    private func once(at url: URL, _ change: @escaping @Sendable () throws -> Void) -> @Sendable (URL) async -> Void {
        let done = Mutex(false)
        return { written in
            guard written.standardizedFileURL.path == url.standardizedFileURL.path,
                  done.withLock({ done in defer { done = true }; return !done }) else { return }
            try? change()
        }
    }

    @Test func anEditMadeWhileAFileIsWrittenIsNeverWrittenOver() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        // The user corrects a label in the very file the flush has just read.
        await w.records.setBeforeWriting(once(at: w.topListing) { _ = try w.editLabelByHand() })
        try await w.records.flush()
        let text = try String(contentsOf: w.topListing, encoding: .utf8)
        #expect(text.contains("value: Maria Silva") && text.contains("file: edp_september.txt"),
                "the edit is read back first, and the file then holds both it and the change of the index")
        let parties = try await w.h.services.documents.list(DocumentFilter(), limit: 5).flatMap { $0.labels(.party) }
        #expect(parties.contains("Maria Silva"), "and the edit is the document's")
    }

    @Test func aFileEditedWhileItIsRemovedIsNeverRemoved() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        let rule = try await w.h.labels.merge(DocumentLabel(kind: .sender, value: "EDP Comercial"), into: "EDP")
        try await w.records.flush()
        let url = w.h.env.layout.labelRules
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "target: EDP\n", with: "target: EDP Energia\n")
        try await w.h.labels.forget(rule: try #require(rule.rule.id))
        // With no rule left, the flush removes the file, which the user edits just then.
        await w.records.setBeforeWriting(once(at: url) { try edited.write(to: url, atomically: true, encoding: .utf8) })
        try await w.records.flush()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("target: EDP Energia"), "the file the user edited is not removed")
        #expect(try await w.h.services.labels.rules().map(\.target) == ["EDP Energia"], "and the rule they wrote is read back")
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondFlushWaitsUntilTheFirstHasWritten() async throws {
        let w = try await RecordsWorld.make()
        defer { w.h.env.cleanup() }
        try await w.h.ingest("edp_september.txt", text: "EDP electricity September")
        let hold = Hold()
        await w.records.setBeforeWriting { _ in await hold.arrive() }
        let first = Task { try await w.records.flush() }
        #expect(await Patience.until { hold.arrivals == 1 }, "the first flush has read the file and is about to write it")
        let second = Task { try await w.records.flush() }
        let waiting = await Patience.until { await w.records.waitingTurns == 1 || hold.arrivals > 1 }
        #expect(waiting && hold.arrivals == 1, "the second waits for its turn, rather than reading the file the first is writing")
        hold.open()
        _ = try await first.value
        _ = try await second.value
        #expect(try String(contentsOf: w.topListing, encoding: .utf8).contains("file: edp_september.txt"), "and both end with the file written")
        #expect(try await RecordsWorld.marks(w.h.env.database).isEmpty, "and nothing left to write")
    }
}
