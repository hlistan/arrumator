import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The logic, not the app, decides how deep the tree goes: a logic of four levels and a year folder gets exactly that,
/// through the whole pipeline, from arrival to the file on disk.
@Suite struct FolderPathTests {
    private static let logic = """
        Build paths as Jurisdiction / Subject / Functional Area / Institution or Process / [YYYY Year].
        Year folders only for periodic documents; one-off documents sit directly in the institution's folder.
        """
    private static let bank = ["Portugal", "Hlistan Zolerani LDA", "Banking"]

    /// Answers as a model following `logic` would: statements by year, the agreement not, each bank its own folder.
    private static func model(_ request: OllamaChatRequest) -> String {
        guard Fixtures.isDecision(request) else { return #"{"file_name":"Named by the model"}"# }
        let text = request.messages.last?.content ?? ""
        if text.contains("Millennium") {
            return Fixtures.answer(path: bank + ["Millennium BCP"], description: "Millennium BCP.", correspondent: "Millennium BCP",
                                   subject: "Hlistan Zolerani, Lda.",
                                   confidence: 0.99)
        }
        let periodic = !text.contains("agreement")
        return Fixtures.answer(path: bank + ["Santander"], description: "Santander Totta.", correspondent: "Santander Totta",
                               subject: "Hlistan Zolerani, Lda.",
                               yearly: periodic ? "yes" : "no", confidence: 0.99)
    }

    private func pipeline(_ h: ClassifyHarness) -> IngestCoordinator {
        let naming = h.env.config.naming
        let placer = Placer(builder: FilenameBuilder(config: naming), operations: FileOperations(naming: naming))
        return IngestCoordinator(services: PipelineServices(
            database: h.env.database, config: h.env.config, settings: h.env.settings, taxonomy: h.env.taxonomy,
            extractor: PlainTestExtractor(), classifier: h.classifier, learner: h.learner,
            filer: DocumentFiler(database: h.env.database, placer: placer, index: IndexStore(database: h.env.database),
                                 registry: SelfChangeRegistry(ttl: h.env.config.watcher.selfChangeTTLSeconds)),
            traces: TraceRecorder(database: h.env.database, appVersion: "test"), vectors: VectorIndex()))
    }

    private func directory(of name: String, _ h: ClassifyHarness) async throws -> String {
        let documents = try await DocumentStore(database: h.env.database).list(DocumentFilter(statuses: [.filed]), limit: 10)
        let document = try #require(documents.first { $0.originalFilename == name })
        let root = h.env.archive.standardizedFileURL.path + "/"
        return String(document.url.deletingLastPathComponent().standardizedFileURL.path.dropFirst(root.count))
    }

    @Test func documentsAreFiledAsDeepAsTheLogicSaysWithYearFoldersPerDocument() async throws {
        let h = try await ClassifyHarness.make(handler: Self.model)
        defer { h.env.cleanup() }
        try await h.logic.update(body: Self.logic)
        let coordinator = pipeline(h)
        for (name, text) in [("statement.txt", "Santander Totta extrato de conta julho 2026, saldo final"),
                             ("contract.txt", "Account opening agreement with Santander Totta, signed by the directors"),
                             ("other-bank.txt", "Millennium BCP extrato agosto")] {
            await coordinator.enqueue(try h.env.drop(name, text: text))
            await coordinator.drain()
        }

        let santander = (Self.bank + ["Santander"]).joined(separator: "/")
        #expect(try await directory(of: "statement.txt", h) == santander + "/2026", "a periodic document goes in its year folder")
        #expect(try await directory(of: "contract.txt", h) == santander, "a one-off document in the same folder does not")
        #expect(try await directory(of: "other-bank.txt", h) == (Self.bank + ["Millennium BCP", "2026"]).joined(separator: "/"))

        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        let user = snapshot.folders.filter(\.holdsUserDocuments)
        #expect(user.count == 5, "the levels the documents share were created once")
        #expect(user.map(\.kind) == [.topic, .subject, .topic, .sender, .sender] && user.allSatisfy { $0.logic != nil },
                "each folder remembers what it stands for and which logic made it")
        #expect(user.map(\.name).allSatisfy { !$0.contains(where: \.isNumber) }, "folders are named as the logic names them")
        for folder in user {
            #expect(FileManager.default.fileExists(atPath: snapshot.url(for: folder).appendingPathComponent(h.env.config.taxonomy.aboutFileName).path))
        }
        let requests = await h.mock.chatRequests
        let decision = try #require(requests.last(where: Fixtures.isDecision))
        #expect(decision.allText.contains("Jurisdiction / Subject / Functional Area"), "the model follows the archive's logic")
        #expect(!decision.allText.contains("Banking documents.") && !decision.allText.contains("Santander Totta."),
                "each document is decided from the logic and itself, never from folders to copy")
        #expect(requests.filter(Fixtures.isDecision).count == 3, "each document is decided by one request")
    }

    @Test func anOlderTreeCannotPullADeeperLogicBackIntoItsShape() async throws {
        let h = try await ClassifyHarness.make(handler: Self.model)
        defer { h.env.cleanup() }
        let old = try await h.env.folder(path: ["Finances", "Banks and Cards"], description: "Statements from every bank.")
        try await h.logic.update(body: Self.logic)
        let coordinator = pipeline(h)
        await coordinator.enqueue(try h.env.drop("statement.txt", text: "Santander Totta extrato de conta julho 2026, saldo final"))
        await coordinator.drain()

        #expect(try await directory(of: "statement.txt", h) == (Self.bank + ["Santander", "2026"]).joined(separator: "/"),
                "filed where the logic puts it, four levels down")
        let snapshot = try await h.env.taxonomy.snapshot(root: h.env.archive)
        #expect(snapshot.folder(code: old.code)?.documentCount == 0, "not in the folder the old logic made")
        let requests = await h.mock.chatRequests
        let decision = try #require(requests.first(where: Fixtures.isDecision))
        #expect(!decision.allText.contains("Banks and Cards") && !decision.allText.contains("Statements from every bank."),
                "the decision never sees the older tree")
    }

    @Test func aSendersDocumentsStayTogetherAndNeverJoinAnotherSenders() async throws {
        let answers: [(text: String, path: [String], from: String)] = [
            ("Santander Totta extrato julho", ["Portugal", "Santander Totta"], "Santander Totta"),
            ("Santander Totta extrato agosto", ["Global - Cross-Border", "Banco Santander Totta, S.A."], "Santander Totta"),
            ("MEO fatura agosto", ["Portugal", "Santander Totta"], "MEO"),
        ]
        let h = try await ClassifyHarness.make(handler: { request in
            if Fixtures.isJudge(request) { return Fixtures.choice("unsure") }
            guard Fixtures.isDecision(request), let answer = answers.first(where: { request.allText.contains($0.text) }) else {
                return #"{"file_name":"Named"}"#
            }
            return Fixtures.answer(path: answer.path, description: "\(answer.from) documents.",
                                   correspondent: answer.from, yearly: "no", confidence: 0.99)
        })
        defer { h.env.cleanup() }
        try await h.logic.update(body: "Jurisdiction / Institution.")
        let coordinator = pipeline(h)
        for (index, answer) in answers.enumerated() {
            await coordinator.enqueue(try h.env.drop("doc\(index).txt", text: answer.text))
            await coordinator.drain()
        }

        #expect(try await directory(of: "doc0.txt", h) == "Portugal/Santander Totta")
        #expect(try await directory(of: "doc1.txt", h) == "Portugal/Santander Totta",
                "the sender's second document joins its first, though the model worded the path differently")
        let held = try #require(try await DocumentStore(database: h.env.database).list(DocumentFilter(statuses: [.needsReview]), limit: 10)
            .first { $0.originalFilename == "doc2.txt" })
        #expect(held.decision?.reviewReasons.filter { $0.contains("holds another sender's documents") }.count == 1,
                "a document from another sender is held back, never filed with the bank's")
        #expect(try await h.env.taxonomy.snapshot(root: h.env.archive).folders.filter { $0.name.contains("Santander") }.count == 1)
    }
}
