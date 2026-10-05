@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Testing

/// A folder put at the top of Incoming names a tag (`LabelKind.tag`), the user's own label: every document in it, at any
/// depth, is filed with it beside the labels the model gives. The folder stays where it is, a place to drop files into,
/// and the tag is the user's: kept when a document is read again, never merged unasked, never shown to the model.
@Suite struct TagTests {
    static let folder = "Taxes 2024"
    static let tag = DocumentLabel(kind: .tag, value: "Taxes 2024")
    static let mine = DocumentLabel(kind: .tag, value: "Mine")

    static func given(_ h: Harness, folder name: String = TagTests.folder) -> GivenTag {
        GivenTag(label: DocumentLabel(kind: .tag, value: name), source: .folder, folder: h.env.incoming.appendingPathComponent(name).path)
    }

    static func insights(_ h: Harness) async throws -> Insights {
        try await StatsService(database: h.env.database, config: h.env.config.stats, time: h.env.time).insights()
    }

    // MARK: The kind

    @Test func aTagIsKeptAsWrittenOnOneLineAndCutAtTheLimit() throws {
        let labels = try PipelineConfig.bundledDefaults().labels
        #expect(labels.label("  Taxes\n   2024 ", kind: .tag) == Self.tag, "on one line, trimmed, in the case it is written in")
        #expect(labels.label("École de Musique", kind: .tag)?.value == "École de Musique", "and nothing else changed: no lowercasing, accents kept")
        let cut = try #require(labels.label(String(repeating: "Receipts ", count: 20), kind: .tag)?.value)
        #expect(cut.count <= labels.maxValueChars && cut.hasPrefix("Receipts Receipts") && !cut.hasSuffix(" "),
                "cut as every label is, after the last whole word that fits in labels.maxValueChars")
        #expect(labels.label(" \n ", kind: .tag) == nil, "a name of nothing names no tag")
        let several = [Self.tag, DocumentLabel(kind: .tag, value: "taxes 2024"), Self.mine].distinct()
        #expect(several == [Self.tag, Self.mine], "a document may have several tags, each once however it is cased")
    }

    @Test func aTagIsTheUsersOwnAndNoKindTheModelGives() throws {
        #expect(LabelKind.tag.isUsersOwn && !LabelKind.modelKinds.contains(.tag), "the model is never asked for a tag")
        #expect(LabelKind.modelKinds == LabelKind.allCases.filter { $0 != .tag } && !LabelKind.sender.isUsersOwn,
                "every other kind is the model's, in their order")
        #expect(SearchService.columns.last == LabelKind.tag.rawValue, "a tag is a field of the search, tag:…")
        let labels = try PipelineConfig.bundledDefaults().labels
        #expect(labels.vocabulary.kinds[.tag] == nil && labels.isWrittenFreely(.tag) && labels.isWrittenFreely(.sender)
                    && !labels.isWrittenFreely(.date),
                "tags are not kept one vocabulary, but the user merges or removes them as labels of the kinds that are")
    }

    @Test(.enabled(if: Volume.ignoresCase, "only a volume that ignores case finds a folder by its name in another case"))
    func aFolderNamedInAnotherCaseNamesTheTagAsTheDiskKeepsIt() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = try env.folder("Incoming")
        let scan = incoming.appendingPathComponent("\(Self.folder)/scan.pdf")
        try FileManager.default.createDirectory(at: scan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a document".utf8).write(to: scan)
        let folders = IncomingFolders(incoming: incoming, watcher: env.config.watcher, labels: env.config.labels)
        #expect(folders.tag(of: incoming.appendingPathComponent("\(Self.folder.lowercased())/scan.pdf"))?.label == Self.tag,
                "the folder's name as the disk keeps it, however the path to a file spells it")
    }

    @Test func theFolderAtTheTopOfIncomingNamesTheTagAndNothingElseDoes() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let incoming = env.root.appendingPathComponent("Incoming", isDirectory: true)
        func put(_ path: String) throws -> URL {
            let url = incoming.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("a document".utf8).write(to: url)
            return url
        }
        let folders = IncomingFolders(incoming: incoming, watcher: env.config.watcher, labels: env.config.labels)
        let scan = try put("Taxes 2024/scan.pdf")
        #expect(folders.tag(of: scan) == GivenTag(label: Self.tag, source: .folder,
                                                  folder: incoming.appendingPathComponent(Self.folder).standardizedFileURL.path),
                "a folder placed in Incoming gives its name, as it is written, to what is in it, kept at its path as the index writes paths")
        #expect(folders.tag(of: try put("Taxes 2024/Q1/receipts/deeper.pdf"))?.label == Self.tag,
                "at any depth: only the top folder counts, and the folders inside it give nothing")
        #expect(folders.tag(of: try put("loose.pdf")) == nil, "a file directly in Incoming gets none")
        let package = incoming.appendingPathComponent("Notes.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{\\rtf1 a note}".utf8).write(to: package.appendingPathComponent("TXT.rtf"))
        #expect(try package.resourceValues(forKeys: [.isPackageKey]).isPackage == true, "macOS shows this folder as one document")
        #expect(folders.tag(of: package) == nil && folders.tag(of: package.appendingPathComponent("TXT.rtf")) == nil,
                "so a package at the top of Incoming is a document, not a folder of them")
        let inner = incoming.appendingPathComponent("Taxes 2024/Notes.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(folders.tag(of: inner)?.label == Self.tag, "while one in a folder is a document of that folder")
        #expect(folders.tag(of: try put(".private/scan.pdf")) == nil, "a folder the watcher ignores, such as a hidden one, names nothing")
        #expect(folders.tag(of: env.root.appendingPathComponent("Elsewhere/scan.pdf")) == nil, "nor does a folder outside Incoming")
        #expect(folders.tag(of: incoming) == nil, "nor Incoming itself")
    }

    // MARK: Filing

    @Test func aFolderInIncomingTagsEverythingInItAtAnyDepthAndStaysWhereItIs() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let files = [try h.env.drop("Taxes 2024/scan.txt", text: "EDP electricity July"),
                     try h.env.drop("Taxes 2024/sub/deeper/receipt.txt", text: "EDP electricity August"),
                     try h.env.drop("loose.txt", text: "EDP electricity September")]
        for file in files { await h.coordinator.enqueue(file) }
        let queued = try await h.jobs()
        #expect(queued.map(\.tags) == [[Self.tag], [Self.tag], []],
                "the tag is decided when a file is queued, from where it is in Incoming, and kept with its job before it is read")
        #expect(try queued.first?.payload.tags == [Self.given(h)], "with the folder that gave it")
        await h.coordinator.drain()

        let documents = try await h.services.documents.list(DocumentFilter(), limit: 10)
        func document(_ name: String) throws -> DocumentRecord { try #require(documents.first { $0.originalFilename == name }) }
        let (scan, receipt, loose) = (try document("scan.txt"), try document("receipt.txt"), try document("loose.txt"))
        #expect(scan.labels == StubAnalyzer.edpBill + [Self.tag] && receipt.labels == scan.labels,
                "filed with the tag beside the labels the model gave, at any depth")
        #expect(scan.isLabelled && scan.status == .filed, "and labelled, as the model read it")
        #expect(loose.labels == StubAnalyzer.edpBill, "a file directly in Incoming gets no tag")
        let folder = h.env.incoming.appendingPathComponent(Self.folder).path
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue,
                "the folder stays where it is: the app never moves, renames or removes it")
        let left = try FileManager.default.subpathsOfDirectory(atPath: folder).filter { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(path), isDirectory: &directory) && !directory.boolValue
        }
        #expect(left.isEmpty, "and is left empty of files, every one filed")

        try await h.env.records().flush()
        let listing = try String(contentsOf: h.env.archive.appendingPathComponent(h.env.config.records.documentsFileName), encoding: .utf8)
        #expect(listing.contains("kind: tag") && listing.contains("value: Taxes 2024"), "the tag is in the archive's record of the document")

        let id = try #require(scan.id)
        let reading = try #require(try await h.services.history.events(limit: 20, kinds: [.analysed], docID: id).first)
        #expect(reading.summary == StubAnalyzer.edpBill.map(\.value).joined(separator: " · ") + "; tagged “Taxes 2024” by its folder in Incoming",
                "History says what the model gave it, and that the tag came from its folder")
        #expect(JSON.decode(AnalysedPayload.self, from: reading.payloadJson)?.tags == [Self.given(h)], "naming the folder")
        let arrivals = try await h.services.history.events(limit: 20, kinds: [.arrived]).map(\.summary)
        #expect(arrivals.contains("scan.txt · tagged “Taxes 2024” by its folder in Incoming") && arrivals.contains("loose.txt"),
                "and its arrival says what it will be tagged")
        let trace = try #require(try await h.services.traces.traces(docID: id).first?.id)
        let step = try #require(try await h.services.traces.trace(id: trace)?.1.first { $0.stage == TraceStage.tag.rawValue })
        #expect(JSON.decode([GivenTag].self, from: step.inputJson) == [Self.given(h)], "the trace says which folder gave the tag")
        #expect(JSON.decode(LabelConsolidation.self, from: step.outputJson)?.labels == [Self.tag], "and the tag it gave")
    }

    @Test func aFileDroppedIntoTheFolderLaterIsTaggedToo() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        try await h.ingest("Taxes 2024/scan.txt", text: "EDP electricity July")
        let later = try await h.ingest("Taxes 2024/later.txt", text: "EDP electricity August")
        #expect(later.labels?.values(.tag) == [Self.folder], "the folder is a place to drop files into: what comes later is tagged too")
    }

    @Test func aDocumentTheModelCannotReadKeepsItsTagWaitsAndIsStillReadAsNotLabelled() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let doc = try await h.ingest("Taxes 2024/bill.txt", text: "EDP electricity July")
        let id = try #require(doc.id)
        #expect(doc.status == .needsReview && doc.labels == [Self.tag], "it waits for the user with its tag, and nothing the model did not give")
        #expect(doc.tagsOnly && !doc.isLabelled, "it is not labelled: its labels are only the user's own")
        #expect(try await h.services.documents.unlabelled() == [id], "so what reads documents without labels reads it")
        let insights = try await Self.insights(h)
        #expect(insights.labelled == 0 && insights.unlabelled == 1 && insights.labelsByKind[LabelKind.tag.rawValue] == 1,
                "Statistics counts it as not labelled yet, and its tag among the labels by kind")
        let event = try #require(try await h.services.history.events(limit: 20, kinds: [.error], docID: id).first)
        #expect(event.summary == "Not read: the model gave no valid answer; tagged “Taxes 2024” by its folder in Incoming",
                "History says why it was not read, and that it was tagged all the same")

        try await h.env.records().flush()
        let text = try String(contentsOf: h.env.archive.appendingPathComponent(h.env.config.records.documentsFileName), encoding: .utf8)
        #expect(text.contains("tags_only: true") && text.contains("value: Taxes 2024"), "its record keeps the tag, and that it is no more yet")
        let database = try AppDatabase.inMemory()
        try await h.env.records(index: database).rebuild()
        let back = try #require(try await DocumentStore(database: database, time: TestTime(.advances)).document(id: id))
        #expect(back.labels == [Self.tag] && !back.isLabelled, "a rebuild brings back the tag, with the document still not labelled")

        var services = h.services
        services.analyzer = StubAnalyzer()
        let coordinator = IngestCoordinator(services: services)
        try await ReviewActions(services: services, coordinator: coordinator).retry(id)
        #expect(try await services.jobs.active().map(\.tags) == [[Self.tag]], "asked to be read again, it waits showing the tag it keeps")
        await coordinator.drain()
        let read = try #require(try await services.documents.document(id: id))
        #expect(read.labels == StubAnalyzer.edpBill + [Self.tag] && read.isLabelled && read.status == .filed,
                "read again, it is labelled with what the model gives and keeps its tag")
        #expect(try await services.documents.unlabelled().isEmpty, "and no longer waits for labels")
    }

    @Test func readingADocumentAgainKeepsItsTags() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("Taxes 2024/bill.txt", text: "EDP electricity July").id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.mine]))
        h.env.time.advance(by: 60)
        var services = h.services
        services.analyzer = StubAnalyzer(labels: LabelingTests.meoContract)
        let coordinator = IngestCoordinator(services: services)
        try await ReviewActions(services: services, coordinator: coordinator).retry(id)
        await coordinator.drain()
        let read = try #require(try await services.documents.document(id: id))
        #expect(read.labels == LabelingTests.meoContract + [Self.tag, Self.mine],
                "read again, it has what the model reads now, and keeps its tags: the folder's and the one added by hand")
        let event = try #require(try await services.history.events(limit: 20, kinds: [.analysed], docID: id).first)
        #expect(event.summary == LabelingTests.meoContract.map(\.value).joined(separator: " · ") + "; keeps its tags “Taxes 2024”, “Mine”",
                "History says the tags were kept")
    }

    @Test func aTagGivenByHandLeavesADocumentNotYetLabelledAsItWas() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.mine]))
        let tagged = try #require(try await h.services.documents.document(id: id))
        let waiting = try await h.services.documents.unlabelled()
        #expect(tagged.labels == [Self.mine] && !tagged.isLabelled && waiting == [id],
                "a tag is the user's own and labels nothing: the document still waits for the model")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(removing: [Self.mine]))
        let untagged = try #require(try await h.services.documents.document(id: id))
        #expect(untagged.labels == nil && !untagged.isLabelled, "and without it, the document has no labels at all, as before")
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.mine, DocumentLabel(kind: .sender, value: "EDP")]))
        let labelled = try #require(try await h.services.documents.document(id: id))
        let left = try await h.services.documents.unlabelled()
        #expect(labelled.isLabelled && left.isEmpty,
                "a label of another kind given by hand labels it, as one did before tags")
    }

    // MARK: The user's words

    @Test func theUsersRulesApplyToTagsAndNothingElseMergesThem() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let a = try #require(try await h.ingest("Taxes 2024/a.txt", text: "EDP electricity July").id)
        _ = try await h.ingest("Taxes 2024/b.txt", text: "EDP electricity August")
        let alike = try #require(try await h.ingest("Taxes-2024/c.txt", text: "EDP electricity September").id)
        func tags(_ id: Int64) async throws -> [String]? { try await h.services.documents.document(id: id)?.labels(.tag) }
        #expect(try await tags(alike) == ["Taxes-2024"],
                "a tag written alike to one more documents have stays as its folder writes it: the user's words are never merged unasked")
        #expect(try await h.services.labels.suggestions().allSatisfy { $0.kind != .tag }, "nor offered to merge under Look Alike")

        let receipt = try #require(try await h.ingest("Receipts/r1.txt", text: "EDP electricity October").id)
        try await h.labels.ignore(DocumentLabel(kind: .tag, value: "receipts"))
        #expect(try await tags(receipt) == [], "a tag the user removes everywhere is taken off every document")
        let unwanted = try await h.ingest("Receipts/r2.txt", text: "EDP electricity November")
        #expect(unwanted.labels?.values(.tag) == [], "and is not given again by its folder")

        try await h.labels.merge(DocumentLabel(kind: .tag, value: "Taxes-2024"), into: "Taxes")
        let (rewritten, first) = (try await tags(alike), try await tags(a))
        #expect(rewritten == ["Taxes"] && first == ["Taxes"],
                "a tag merged into another is written as the user wants it, on every document that has it, written however")
        let merged = try #require(try await h.ingest("Taxes-2024/d.txt", text: "EDP electricity December").id)
        #expect(try await tags(merged) == ["Taxes"], "and so is one its folder gives from then on")
        let trace = try #require(try await h.services.traces.traces(docID: merged).first?.id)
        let step = try #require(try await h.services.traces.trace(id: trace)?.1.first { $0.stage == TraceStage.tag.rawValue })
        #expect(JSON.decode(LabelConsolidation.self, from: step.outputJson)?.changes.count == 1, "the trace says the rule changed it")
    }

    @Test func theConsolidatorNeverMergesATagWithOneInUseOnItsOwn() throws {
        var config = try PipelineConfig.bundledDefaults().labels.vocabulary
        // Even were tags kept one vocabulary, as a configuration the app refuses would have them, as names are.
        config.kinds[.tag] = config.kinds[.sender]
        let inUse = [LabelKind.tag: [LabelUsage(label: Self.tag, documents: 9)],
                     .sender: [LabelUsage(label: DocumentLabel(kind: .sender, value: "EDP Comercial"), documents: 9)]]
        let consolidator = LabelConsolidator(config: config, rules: [], vocabulary: inUse)
        let written = DocumentLabel(kind: .tag, value: "taxes-2024")
        #expect(consolidator.ruled([written]).labels == [written] && consolidator.ruled([written]).changes.isEmpty,
                "a tag written like one in use stays as written")
        #expect(consolidator.consolidate([DocumentLabel(kind: .sender, value: "edp comercial")]).labels.values(.sender) == ["EDP Comercial"],
                "while the model's labels are tidied to the archive's as before")
        let ruled = LabelConsolidator(config: config, rules: [LabelRule(id: 1, kind: .tag, value: "Taxes 2024", action: .merge, target: "Taxes",
                                                                        createdAt: TestTime.start)], vocabulary: inUse)
        #expect(ruled.ruled([written]).labels == [DocumentLabel(kind: .tag, value: "Taxes")], "a rule of the user's applies, as to any label")
    }

    @Test func aRuleAboutATagLeavesADocumentNotLabelledSo() async throws {
        let h = try await Harness.make(analyzer: StubAnalyzer(labels: nil))
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("Taxes 2024/bill.txt", text: "EDP electricity July").id)
        try await h.labels.merge(Self.tag, into: "Taxes")
        let merged = try #require(try await h.services.documents.document(id: id))
        #expect(merged.labels == [DocumentLabel(kind: .tag, value: "Taxes")] && !merged.isLabelled,
                "a merge rewrites the tag of a document the model has not read, which stays not labelled")
        try await h.labels.ignore(DocumentLabel(kind: .tag, value: "Taxes"))
        let ignored = try #require(try await h.services.documents.document(id: id))
        let waiting = try await h.services.documents.unlabelled()
        #expect(ignored.labels == nil && !ignored.isLabelled && waiting == [id],
                "and taking its only tag off leaves it with no labels at all, still waiting for the model")
    }

    @Test func theModelIsShownNothingOfTheTags() async throws {
        let analyzer = StubAnalyzer()
        let h = try await Harness.make(analyzer: analyzer)
        defer { h.env.cleanup() }
        try await h.ingest("Taxes 2024/a.txt", text: "EDP electricity July")
        try await h.ingest("Receipts/b.txt", text: "EDP electricity August")
        try await h.labels.merge(Self.tag, into: "Taxes")
        try await h.labels.ignore(DocumentLabel(kind: .tag, value: "Receipts"))
        try await h.ingest("c.txt", text: "EDP electricity September")
        let guidance = try #require(await analyzer.calls.guidance.last)
        #expect(guidance.used[.tag] == nil && !guidance.preferred.contains { $0.from.kind == .tag } && !guidance.unwanted.contains { $0.kind == .tag },
                "the model is never told of the user's tags, nor of the decisions about them")
        #expect(guidance.used[.sender] == ["EDP Comercial"], "while it is told of the archive's other labels, as before")
    }

    // MARK: Copies, files of the archive, search

    @Test func aCopyInAFolderInIncomingGivesItsOriginalTheFolderTagAndHasItReadAgain() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let id = try #require(try await h.ingest("bill.txt", text: "EDP electricity July").id)
        try await h.review.edit(id, fileName: nil, labels: LabelEdit(adding: [Self.mine]))
        h.env.time.advance(by: 60)
        let (services, coordinator, analyzer) = h.readingOtherwise()
        await coordinator.enqueue(try h.env.drop("Taxes 2024/bill copy.txt", text: "EDP electricity July"))
        await coordinator.drain()

        let read = try #require(try await services.documents.document(id: id))
        #expect(read.labels == LabelingTests.meoContract + [Self.mine, Self.tag],
                "read again, it has what the model reads now, the tag it had, and the tag of its copy's folder")
        let (files, documents) = (await analyzer.calls.files, try await services.documents.list(DocumentFilter(), limit: 5))
        #expect(files.count == 1 && documents.map(\.id) == [id], "the original is read once, and the copy is no document of its own")
        #expect(try await services.documents.list(DocumentFilter(labels: [Self.tag]), limit: 5).map(\.id) == [id],
                "the original is found under the folder's tag")
        let event = try #require(try await services.history.events(limit: 5, kinds: [.duplicate], docID: id).first)
        #expect(event.summary.hasSuffix("the copy is in the Trash; tagged “Taxes 2024” by its folder in Incoming"),
                "History says what gave the original its tag: \(event.summary)")
        #expect(JSON.decode(CopyPayload.self, from: event.payloadJson)?.tags == [Self.given(h)], "and keeps the folder that gave it")
        let traceID = try #require(event.traceId)
        let steps = try #require(try await services.traces.trace(id: traceID)?.1)
        #expect(steps.map(\.stage) == [TraceStage.hash, .dedupe, .tag].map(\.rawValue), "the copy's trace records the tag it gave, after checking it is a copy")
        let analysed = try #require(try await services.history.events(limit: 5, kinds: [.analysed], docID: id).first)
        #expect(analysed.summary.hasSuffix("; keeps its tags “Mine”, “Taxes 2024”"), "and the reading keeps it: \(analysed.summary)")
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: h.env.incoming.appendingPathComponent(Self.folder).path, isDirectory: &isFolder)
                    && isFolder.boolValue, "the folder stays in Incoming, a place to drop files into")
    }

    @Test func aFolderOfTheUsersInTheArchiveGivesNoTag() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let put = try h.env.put("Taxes 2024/receipt.txt", text: "A receipt")
        try await ArchiveReconciler(services: h.services, coordinator: h.coordinator).apply([.found(path: put.path)])
        await h.coordinator.drain()
        let doc = try #require(try await h.services.documents.document(path: put.path))
        #expect(doc.labels == StubAnalyzer.edpBill, "a file the user put into the archive is read where it is, and its folder is no tag")
    }

    @Test func aTagIsFoundBySearchListedInTheSidebarAndCountedByKind() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let tagged = try await h.ingest("Taxes 2024/a.txt", text: "EDP electricity July")
        try await h.ingest("b.txt", text: "EDP electricity August")
        let search = h.search
        #expect(try await search.fullText(SearchQuery(text: "tag:\"taxes 2024\"")).hits.map(\.id) == [tagged.id],
                "tag:… finds the documents with the tag, however it is cased")
        #expect(try await search.fullText(SearchQuery(text: "sender:\"taxes 2024\"")).hits.isEmpty, "under its own kind only")
        #expect(try await h.services.labels.usage()[.tag] == [LabelUsage(label: Self.tag, documents: 1)],
                "the sidebar lists it with how many documents have it")
        #expect(try await Self.insights(h).labelsByKind[LabelKind.tag.rawValue] == 1, "and Statistics counts it among the labels by kind")
    }

    @Test func whatAFileWouldBeGivenIsShownWithoutFilingIt() async throws {
        let h = try await Harness.make()
        defer { h.env.cleanup() }
        let settings = await h.env.settings.current
        let url = try h.env.drop("Taxes 2024/scan.txt", text: "EDP electricity July")
        let given = h.services.tags(for: url, given: ["  Mine ", "taxes 2024"], settings: settings)
        #expect(given == [Self.given(h), GivenTag(label: Self.mine, source: .command, folder: nil)],
                "the folder's tag first, then those given on the command line, each once")
        let many = h.services.tags(for: url, given: (1...10).map { "Box \($0)" }, settings: settings)
        #expect(many.count == h.env.config.labels.maxPerKind && many.first == Self.given(h), "at most labels.maxPerKind, the folder's first")
        let content = try await h.services.extractor.extract(url, sha256: "x", context: try h.env.config.extractionContext(settings: settings, whenOllamaIsAway: .wait),
                                                             trace: .disabled)
        let reading = try await h.services.read(content, tags: given.map(\.label), settings: settings, trace: .disabled)
        #expect(reading.outcome.labels == StubAnalyzer.edpBill + [Self.tag, Self.mine], "a dry run shows them beside what the model gives")
        let recorded = try await h.services.documents.list(DocumentFilter(), limit: 5)
        #expect(FileManager.default.fileExists(atPath: url.path) && recorded.isEmpty,
                "without filing or recording anything")
        var unread = h.services
        unread.analyzer = StubAnalyzer(labels: nil)
        let notRead = try await unread.read(content, tags: [Self.tag], settings: settings, trace: .disabled)
        #expect(notRead.outcome.labels == nil && notRead.tags == [Self.tag], "without an answer, the tags are still what it would be given")
    }
}
