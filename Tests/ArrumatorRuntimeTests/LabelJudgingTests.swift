@testable import ArrumatorCore
import ArrumatorRuntime
import ArrumatorTesting
import CryptoKit
import Foundation
import GRDB
import Testing

/// The judge of labels that look alike runs with the runtime's work (docs/how-it-works.md#keeping-labels-one-vocabulary):
/// started with it, woken by a change the app makes and by one another process commits, and stopped with it while it
/// waits for the model's answer.
@Suite struct LabelJudgingTests {
    /// The documents of the archive, each with the party it names, and none of them alike.
    static let documents = [("maria.txt", "Maria Silva"), ("joana.txt", "Joana Costa"), ("rui.txt", "Rui Pinto")]

    /// The list of the archive's documents, each filed with its party, as the app records them: what opening the archive
    /// rebuilds its index from.
    static var list: String {
        let entries = documents.enumerated().map { index, document in
            let (file, party) = document
            let sha = SHA256.hash(data: Data(file.utf8)).map { String(format: "%02x", $0) }.joined()
            return """
            - id: \(index + 1)
              uid: 5B7A8F4E-0000-0000-0000-00000000000\(index + 1)
              file: \(file)
              original_name: \(file)
              added: 2026-07-05T10:00:00Z
              filed: 2026-07-05T10:01:00Z
              status: filed
              content_type: public.plain-text
              size: \(file.utf8.count)
              sha256: \(sha)
              labels:
              - kind: party
                value: \(party)
            """
        }
        return "---\narrumator: 1\nentries:\n" + entries.joined(separator: "\n") + "\n---\n"
    }

    /// The model's answer to every pair it is asked about: two people.
    static let different: LoopbackOllama.Answer = ("200 OK", #"{"model":"loopback","message":{"role":"assistant","content":"#
        + #""{\"reason\":\"Two people.\",\"answer\":\"different\"}"},"done":true,"done_reason":"stop"}"#)

    private func party(_ value: String) -> DocumentLabel { DocumentLabel(kind: .party, value: value) }

    private func outcomes(_ runtime: ArrumatorRuntime) async throws -> [String?] {
        try await runtime.database.reader.read { db in
            try TraceRecord.filter(Column("source") == TraceSource.labels.rawValue).order(Column("id")).fetchAll(db).map(\.outcome)
        }
    }

    /// A scratch home whose archive holds `documents`, with Ollama at `ollama`, waited for as long as a loaded machine may
    /// take.
    private func home(_ ollama: LoopbackOllama) async throws -> RuntimeHome {
        let home = try await RuntimeHome.make(ollama: .at(ollama.address))
        try home.tune("ollama", ["timeouts": .object(["meta": .number(60), "version": .number(60), "resolve": .number(60)])])
        let archive = home.folder("First")
        try home.writeList(Self.list, in: archive)
        for (file, _) in Self.documents { try Data(file.utf8).write(to: archive.appendingPathComponent(file)) }
        return home
    }

    @Test func theRuntimeJudgesWhatItAndAnotherProcessChangeAndStopsWhileTheModelIsAsked() async throws {
        let ollama = try LoopbackOllama(chat: Self.different)
        defer { ollama.stop() }
        let home = try await home(ollama)
        defer { home.cleanup() }
        let app = try await home.open()
        await app.start()

        // The app's own change: the judge, woken, asks the model and keeps the two apart.
        try await app.review.edit(2, fileName: nil, labels: LabelEdit(adding: [party("Mario Silva")]))
        #expect(await Patience.until { (try? await app.services.labels.rules().map(\.action)) == [.keepApart] },
                "the pair the app's change made is judged, and kept apart")

        // Another process's change, as `arrumatorcli labels` beside the app: the app's judge takes it up at once, and the
        // model is still answering when the app stops.
        ollama.holdChats(true)
        let command = try await home.open()
        try await command.review.edit(3, fileName: nil, labels: LabelEdit(adding: [party("Joana Costas")]))
        #expect(await Patience.until { ollama.chatsReceived == 2 }, "the pair the command made is put to the model")
        let stopped = Task { await app.stop() }
        #expect(await Patience.until { (try? await outcomes(app))?.last == LabelJudge.stoppedOutcome },
                "the app stops while the model is asked, and the judgement's trace says it stopped")
        await stopped.value
        #expect(try await outcomes(app) == [LabelJudgement.different.rawValue, LabelJudge.stoppedOutcome], "one judged, one stopped")
        #expect(try await app.services.labels.rules().count == 1, "and nothing is decided about the pair")
        await command.stop()
    }
}
