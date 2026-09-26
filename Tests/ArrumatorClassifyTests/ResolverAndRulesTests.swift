@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

@Suite struct CorrespondentResolverTests {
    let config: PipelineConfig
    init() throws { config = try PipelineConfig.bundledDefaults() }

    func resolver(_ list: [Correspondent]) -> CorrespondentResolver {
        CorrespondentResolver(correspondents: list, config: config.classification, entities: config.entities)
    }

    @Test func learnedIdentifierBeatsName() {
        let edp = Correspondent(id: 1, canonicalName: "EDP", aliases: ["EDP Comercial"], stableKeys: ["ptNIF:503504564"], origin: .learned)
        let other = Correspondent(id: 2, canonicalName: "Galp", origin: .learned)
        let c = Fixtures.content("f.pdf", text: Fixtures.edpText, keys: [StableKey(kind: .ptNIF, value: "503504564")])
        let matches = resolver([edp, other]).resolve(c)
        #expect(matches.first?.correspondent.id == 1 && matches.first?.matchedBy == .stableKey)
        #expect(!matches.contains { $0.correspondent.id == 2 })
    }

    @Test func namesMatchAcrossScriptsIgnoringLegalForms() {
        let sber = Correspondent(id: 3, canonicalName: "Сбербанк", origin: .learned)
        let c = Fixtures.content("v.pdf", text: "ПАО Сбербанк России. Выписка по счёту", language: "ru")
        #expect(resolver([sber]).resolve(c).first?.matchedBy == .name)
        #expect(resolver([sber]).known("ПАО Сбербанк")?.id == 3)
    }

    @Test func shortNamesNeedExactCase() {
        let nos = Correspondent(id: 4, canonicalName: "NOS", origin: .learned)
        #expect(resolver([nos]).resolve(Fixtures.content("a.pdf", text: "Enviamos para nos todos")).isEmpty)
        #expect(resolver([nos]).resolve(Fixtures.content("a.pdf", text: "Fatura NOS Comunicações")).first?.correspondent.id == 4)
    }
}

@Suite struct RuleEngineTests {
    let config: PipelineConfig
    init() throws { config = try PipelineConfig.bundledDefaults() }

    @Test func rulesMatchWhenAllPredicatesHold() {
        let rule = FilingRule(id: 7, name: "EDP invoices", priority: 10, origin: .user,
                              predicates: [.stableKey(token: "ptNIF:503504564"), .filenameGlob("*.pdf"), .textRegex(pattern: "fatura")],
                              action: RuleAction(folderID: 1, folderCode: "11"))
        let engine = RuleEngine(rules: [rule], senders: [], config: config.classification)
        let c = Fixtures.content("f.pdf", text: Fixtures.edpText, keys: [StableKey(kind: .ptNIF, value: "503504564")])
        #expect(engine.evaluateBeforeModel(c, matches: [], detectedType: nil).0?.rule.id == 7)
        let miss = Fixtures.content("f.txt", text: Fixtures.edpText, keys: [StableKey(kind: .ptNIF, value: "503504564")])
        #expect(engine.evaluateBeforeModel(miss, matches: [], detectedType: nil).0 == nil)
    }

    @Test func typeConditionsNeedAnEstimateBeforeTheModel() {
        let rule = FilingRule(id: 8, name: "ids", priority: 10, origin: .induced, predicates: [.documentType(.idDocument)],
                              action: RuleAction(folderID: 1, folderCode: "11"))
        let engine = RuleEngine(rules: [rule], senders: [], config: config.classification)
        let c = Fixtures.content("p.pdf", text: "Passport")
        #expect(engine.evaluateBeforeModel(c, matches: [], detectedType: nil).0 == nil)
        #expect(engine.evaluateBeforeModel(c, matches: [], detectedType: .idDocument).0 != nil)
        #expect(engine.evaluateAfterModel(c, matches: [], documentType: .idDocument).0 != nil)
    }

    @Test func aRuleNamesTheSenderItIsAbout() {
        let edp = Correspondent(id: 12, canonicalName: "EDP Comercial", origin: .learned)
        let rule = FilingRule(id: 9, name: "EDP · invoice → Home / Utilities", priority: 50, origin: .induced,
                              predicates: [.correspondent(id: 12), .documentType(.invoice)],
                              action: RuleAction(folderID: 1, folderCode: "F2", documentType: .invoice, correspondentID: 12))
        #expect(rule.senderID == 12)
        #expect(rule.condition { Correspondent.names([edp])[$0] } == "from EDP Comercial and document type invoice")
        #expect(rule.condition { _ in nil } == "from \(RulePredicate.forgottenSender) and document type invoice",
                "a database id never stands in for a sender")
        let engine = RuleEngine(rules: [rule], senders: [edp], config: config.classification)
        let (_, evaluations) = engine.evaluateAfterModel(Fixtures.content("f.pdf", text: Fixtures.edpText), matches: [],
                                                         documentType: .invoice)
        #expect(evaluations.first?.predicates.map(\.predicate) == ["from EDP Comercial", "document type invoice"],
                "the trace says which sender a condition is about")
        #expect(FilingRule(name: "text", priority: 10, origin: .user, predicates: [.textRegex(pattern: "x")],
                           action: RuleAction(folderID: 1, folderCode: "F2")).senderID == nil)
    }

    @Test func reliabilityWeighsContradictionsNotUses() {
        var rule = FilingRule(name: "r", priority: 10, origin: .induced, predicates: [], action: RuleAction(folderID: 1, folderCode: "11"),
                              support: 3)
        #expect(rule.reliability == 1)
        rule.contradictions = 1
        #expect(rule.reliability == 0.75)
        rule.hits = 100
        #expect(rule.reliability == 0.75)
    }
}

@Suite struct ValidationAndCalibrationTests {
    let config: PipelineConfig
    init() throws { config = try PipelineConfig.bundledDefaults() }

    func validator(logic: String? = nil) -> AnswerValidator {
        AnswerValidator(config: config.classification, entities: config.entities, naming: config.naming, languages: config.extraction.languages,
                        maxDepth: config.taxonomy.maxDepth, logic: logic)
    }

    private func folder(_ id: Int64, _ name: String, in parent: TaxonomyFolder? = nil, origin: FolderOrigin = .learned,
                        role: FolderRole? = nil, kind: LevelKind? = nil, logic: String? = nil, senders: Set<Int64> = [],
                        types: Set<DocumentType> = [], documents: Int = 0, description: String = "") -> TaxonomyFolder {
        TaxonomyFolder(id: id, code: "F\(id)", name: name, parentCode: parent?.code,
                       relativePath: (parent.map { $0.relativePath + "/" } ?? "") + name, role: role, description: description,
                       origin: origin, documentCount: documents, kind: kind, logic: logic, senders: senders, documentTypes: types)
    }

    private func levels(_ names: String...) -> [FolderLevel] { names.map { FolderLevel(name: $0, description: "\($0) documents.", kind: .topic) } }

    /// The levels of a path by the logic "jurisdiction / sender".
    private func byJurisdiction(_ jurisdiction: String, sender: String) -> [FolderLevel] {
        [FolderLevel(name: jurisdiction, description: "\(jurisdiction) documents.", kind: .topic),
         FolderLevel(name: sender, description: "Documents from \(sender).", kind: .sender)]
    }

    private static let logic = "a1b2c3"

    private func place(_ ideal: [FolderLevel], sender: Int64? = nil, type: DocumentType = .invoice, yearFolder: Bool = false,
                       in taxonomy: TaxonomySnapshot, vectors: [String: [Float]] = [:], judge: StubJudge = StubJudge()) async throws -> GuardedPlacement {
        try await PlacementGuard(config: config.classification.placementGuard)
            .place(ideal, sender: sender, documentType: type, logic: Self.logic, yearFolder: yearFolder, taxonomy: taxonomy,
                   vectors: vectors, judge: judge)
    }

    /// A unit vector whose cosine with the first axis is `cosine`, the rest of it along its own `axis`.
    private func alike(_ cosine: Float, axis: Int, dimensions: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[0] = cosine
        v[axis] = (1 - cosine * cosine).squareRoot()
        return v
    }

    private func level(_ name: String, _ kind: LevelKind) -> FolderLevel { FolderLevel(name: name, description: "\(name).", kind: kind) }

    @Test func answerIsNormalised() throws {
        let v = try validator().validate("<think>hmm</think>" + Fixtures.answer(confidence: 1.7))
        #expect(v.ideal.map(\.name) == ["Home", "Utilities"] && v.ideal.last?.description == "Electricity, gas and water bills.")
        #expect(v.yearFolder && v.documentType == .invoice && v.documentDate == "2026-07-05")
        #expect(v.tags == ["energy"] && v.confidence == 1)
        #expect(v.raw.fileName == "2026-07-05 EDP - Fatura eletricidade junho")
    }

    @Test func thePathIsAsDeepAsTheLogicSays() throws {
        let deep = try validator().validate(Fixtures.answer(path: ["Portugal", "Hlistan Zolerani LDA", "Banking", "Santander"], yearly: "no"))
        #expect(deep.ideal.map(\.name) == ["Portugal", "Hlistan Zolerani LDA", "Banking", "Santander"] && !deep.yearFolder)
        let digits = try validator().validate(Fixtures.answer(path: ["Money", "2025 Taxes"]))
        #expect(digits.ideal.last?.name == "2025 Taxes", "a name that starts with digits is no year")
    }

    @Test func whatALogicSpellsOutIsNormalisedNotRejected() throws {
        let yearLast = try validator().validate(Fixtures.answer(path: ["Portugal", "Banking", "Santander", "2026"], yearly: "no"))
        #expect(yearLast.ideal.map(\.name) == ["Portugal", "Banking", "Santander"] && yearLast.yearFolder,
                "a logic's “[YYYY Year]” level is the year folder")
        let slash = try validator().validate(Fixtures.answer(path: ["Global / Cross-Border", "Banking"]))
        #expect(slash.ideal.first?.name == "Global - Cross-Border", "a separator in a name is cleaned as in file names")
        let repeated = try validator().validate(Fixtures.answer(path: ["Portugal", "portugal", "Taxes"]))
        #expect(repeated.ideal.map(\.name) == ["Portugal", "Taxes"], "a level repeating the one above is dropped")
        #expect(repeated.notes.contains { $0.contains("repeats") } && slash.notes.contains { $0.contains("Global - Cross-Border") })
    }

    @Test func aPathOfTheLogicsOwnLevelNamesIsSentBackForRepair() throws {
        let logic = "Build paths as Jurisdiction / Subject / Functional Area / Institution or Process / [YYYY Year]."
        let echoed = Fixtures.answer(path: ["Jurisdiction", "Subject", "Functional Area", "Institution or Process"])
        #expect(throws: AnswerValidationError.self, "the logic's names for its levels are no folders") {
            try validator(logic: logic).validate(echoed)
        }
        #expect(try validator(logic: logic).validate(Fixtures.answer(path: ["Portugal", "Acme Lda", "Banking", "Santander"])).ideal.count == 4)
        #expect(throws: AnswerValidationError.self, "nor is any one of them, where the logic lays its levels out") {
            try validator(logic: logic).validate(Fixtures.answer(path: ["Jurisdiction", "Portugal", "Taxes", "AT"]))
        }
        #expect(try validator(logic: "Keep a folder per Subject you care about.").validate(Fixtures.answer(path: ["Subject"])).ideal.map(\.name)
                == ["Subject"], "a word the logic merely uses can still be a folder's name")
        #expect(try validator(logic: logic).validate(Fixtures.answer(path: ["Portugal", "Taxes"])).ideal.count == 2)
        #expect(try validator(logic: logic).validate(Fixtures.answer(path: ["Portugal", "Process"])).ideal.count == 2,
                "a word inside one of the logic's level names is no echo")
    }

    @Test func invalidAnswersAreRejected() {
        let tooDeep = (0...config.taxonomy.maxDepth).map { "Level \($0)" }
        for path in [[], tooDeep, ["Home", ""], ["Health", "medical-report"], ["Money", "2025", "Taxes"]] {
            #expect(throws: AnswerValidationError.self, "\(path)") { try validator().validate(Fixtures.answer(path: path)) }
        }
        #expect(throws: AnswerValidationError.self) { try validator().validate("not json") }
    }

    @Test func thePathIsFollowedDownTheTreeAndTheRestCreated() async throws {
        let home = folder(1, "Home")
        let utilities = folder(2, "Utilities", in: home)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [home, utilities])
        let existing = try await place(levels("Home", "Utilities"), yearFolder: true, in: taxonomy)
        #expect(existing.folderCode == "F2" && existing.newFolder == nil && existing.idealSimilarity == 1)
        let beside = try await place(levels("Home", "Water"), yearFolder: true, in: taxonomy)
        #expect(beside.folderCode == nil && beside.newFolder?.parentCode == "F1" && beside.newFolder?.levels.map(\.name) == ["Water"])
        #expect(beside.newFolder?.yearSubfolders == true, "the document's year folder sets the new folder's")
        #expect(beside.newFolder?.logic == Self.logic && beside.newFolder?.levels.first?.kind == .topic,
                "a new folder remembers the logic that made it and what it stands for")
        let elsewhere = try await place(levels("Portugal", "Acme Lda", "Banking"), in: taxonomy)
        #expect(elsewhere.newFolder?.parentCode == nil && elsewhere.newFolder?.levels.count == 3)
        #expect(try await place(levels("Home"), in: taxonomy).folderCode == "F1",
                "a folder with folders inside is a home too, when the logic says so")
    }

    @Test func nearDuplicatesAreTheSameFolderButOtherQualifiersAreNot() async throws {
        let money = folder(1, "Money")
        let utilities = folder(2, "Utilities", in: money)
        let pt = folder(3, "Taxes (Portugal)", in: money)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [money, utilities, pt])
        let tax: [Float] = [1, 0]
        let names: [String: [Float]] = ["Money": [0, 1], "Utilities": [0, 1], "Household Utilities": VectorCodec.normalized([0.1, 1]),
                                        "Taxes (Portugal)": tax, "Taxes (Russia)": tax]
        let near = try await place(levels("Money", "Household Utilities"), in: taxonomy, vectors: names)
        #expect(near.folderCode == "F2" && (near.idealSimilarity ?? 0) >= config.classification.placementGuard.duplicateAbove)
        let russia = try await place(levels("Money", "Taxes (Russia)"), in: taxonomy, vectors: names)
        #expect(russia.folderCode == nil && russia.newFolder?.name == "Taxes (Russia)", "another country's taxes are another folder")
        let unembedded = try await place(levels("Money", "Household Utilities"), in: taxonomy)
        #expect(unembedded.newFolder?.name == "Household Utilities", "without embeddings only the same name is the same folder")
        #expect(PlacementGuard.qualifier("Impostos (Portugal) ") == "portugal")
    }

    @Test func aSendersFolderIsFoundByItsSenderWhateverTheModelCallsIt() async throws {
        let portugal = folder(1, "Portugal", kind: .topic, logic: Self.logic)
        let edp = folder(2, "EDP Comercial", in: portugal, kind: .sender, logic: Self.logic, senders: [7], documents: 2)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [portugal, edp])
        let reworded = try await place(byJurisdiction("Portugal", sender: "EDP – Comercialização de Energia, S.A."), sender: 7, in: taxonomy)
        #expect(reworded.folderCode == "F2", "the sender's documents join its folder however the model spells its name")
        let elsewhere = try await place(byJurisdiction("Global - Cross-Border", sender: "EDP"), sender: 7, in: taxonomy)
        #expect(elsewhere.folderCode == "F2", "and wherever the model puts the levels above it")
        let olderLogic = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [portugal,
            folder(2, "EDP Comercial", in: portugal, kind: .sender, logic: "an earlier logic", senders: [7], documents: 2)])
        #expect(try await place(byJurisdiction("Global - Cross-Border", sender: "EDP"), sender: 7, in: olderLogic).folderCode == nil,
                "a folder an earlier logic made does not pull the path back to the older shape")
        let shallower = [FolderLevel(name: "EDP", description: "EDP.", kind: .sender)]
        #expect(try await place(shallower, sender: 7, in: taxonomy).folderCode == "F2",
                "however many levels the model gives the path this time")
    }

    @Test func aSendersFolderIsFoundOnlyUnderTheSubjectTheDocumentIsAbout() async throws {
        let acme = folder(1, "Acme Lda", kind: .subject, logic: Self.logic)
        let maria = folder(2, "Maria", kind: .subject, logic: Self.logic)
        let forAcme = folder(3, "Santander", in: acme, kind: .sender, logic: Self.logic, senders: [7], documents: 3)
        let forMaria = folder(4, "Santander", in: maria, kind: .sender, logic: Self.logic, senders: [7], documents: 1)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [acme, maria, forAcme, forMaria])
        let personal = try await place([level("Maria", .subject), level("Banco Santander", .sender)], sender: 7, in: taxonomy)
        #expect(personal.folderCode == "F4", "a bank serving the company and the person has a folder for each; the person's goes to theirs")
        let company = try await place([level("Acme Lda", .subject), level("Santander Totta", .sender)], sender: 7, in: taxonomy)
        #expect(company.folderCode == "F3")
        let unsaid = try await place([level("Santander Totta", .sender)], sender: 7, in: taxonomy)
        #expect(unsaid.folderCode == nil, "when the document does not say whom it is about, neither folder is assumed")
        let stranger = try await place([level("Joana", .subject), level("Santander", .sender)], sender: 7, in: taxonomy)
        #expect(stranger.newFolder?.levels.map(\.name) == ["Joana", "Santander"], "a subject the archive does not have yet gets its own")
    }

    @Test func insideASendersFolderALevelJoinsTheFolderHoldingTheSameKindOfDocument() async throws {
        let edp = folder(1, "EDP", kind: .sender, logic: Self.logic, senders: [7], documents: 2)
        let bills = folder(2, "Utilities", in: edp, kind: .topic, logic: Self.logic, senders: [7], types: [.invoice], documents: 2)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [edp, bills])
        let reworded = try await place([level("EDP", .sender), level("Energy", .topic)], sender: 7, type: .invoice, in: taxonomy)
        #expect(reworded.folderCode == "F2", "the sender's invoices go where its invoices are, whatever the model calls that folder")
        let contract = try await place([level("EDP", .sender), level("Contracts", .topic)], sender: 7, type: .contract, in: taxonomy)
        #expect(contract.newFolder?.parentCode == "F1" && contract.newFolder?.levels.map(\.name) == ["Contracts"],
                "another kind of document from the sender gets a folder of its own beside them")
        let outside = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [folder(1, "Home"), folder(2, "Utilities", in: folder(1, "Home"),
                                                                                                         types: [.invoice])])
        #expect(try await place(levels("Home", "Energy"), type: .invoice, in: outside).folderCode == nil,
                "outside a sender's folder, a document's type is no reason to join a folder of another name")
    }

    @Test func aKnownSendersDocumentReachesItsFolderWhateverTheModelDoesWithTheLevels() async throws {
        let portugal = folder(1, "Portugal", kind: .topic, logic: Self.logic)
        let maria = folder(2, "Maria Exemplo", in: portugal, kind: .subject, logic: Self.logic)
        let edp = folder(3, "EDP Comercial", in: maria, kind: .sender, logic: Self.logic, senders: [7], types: [.invoice], documents: 1)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [portugal, maria, edp])
        let dropped = try await place([level("Portugal", .topic), level("Maria Exemplo", .subject), level("Utilities", .topic)],
                                      sender: 7, in: taxonomy)
        #expect(dropped.folderCode == "F3", "the model leaving the sender out of the path does not take its document elsewhere")
        let appended = try await place([level("Portugal", .topic), level("EDP Comercial", .sender), level("Utilities", .topic)],
                                       sender: 7, in: taxonomy)
        #expect(appended.folderCode == "F3", "nor does a level the model adds after it, when the folder already holds such documents")
        let other = try await place([level("Portugal", .topic), level("EDP Comercial", .sender), level("Contracts", .topic)],
                                    sender: 7, type: .contract, in: taxonomy)
        #expect(other.newFolder?.parentCode == "F3", "another kind of document from it still gets a folder of its own inside")
        let someoneElse = try await place([level("Portugal", .topic), level("João", .subject), level("Utilities", .topic)],
                                          sender: 7, in: taxonomy)
        #expect(someoneElse.folderCode == nil, "a document about someone else is not taken to the sender's folder for Maria")
    }

    @Test func anotherSendersFolderIsNeverReusedEvenUnderTheSameName() async throws {
        let portugal = folder(1, "Portugal", kind: .topic, logic: Self.logic)
        let edp = folder(2, "EDP Comercial", in: portugal, kind: .sender, logic: Self.logic, senders: [7], documents: 2)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [portugal, edp])
        for sender in [Int64(8), nil] {
            let copied = try await place(byJurisdiction("Portugal", sender: "EDP Comercial"), sender: sender, in: taxonomy)
            #expect(copied.folderCode == nil && copied.newFolder == nil && copied.conflict?.contains("another sender's documents") == true,
                    "a document from someone else, known or not, is held back rather than filed with EDP's")
        }
        let asTopic = try await place(levels("Portugal", "EDP Comercial"), sender: 8, in: taxonomy)
        #expect(asTopic.conflict != nil, "nor when the model calls that level a topic")
        let names: [String: [Float]] = ["Portugal": [1, 0], "EDP Comercial": [0, 1], "EDP Comercial SA": VectorCodec.normalized([0.05, 1])]
        let near = try await place(byJurisdiction("Portugal", sender: "EDP Comercial SA"), sender: 8, in: taxonomy, vectors: names)
        #expect(near.newFolder?.levels.map(\.name) == ["EDP Comercial SA"], "nor under a near-duplicate name")
        let legacy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [portugal, folder(2, "EDP Comercial", in: portugal, senders: [7])])
        #expect(try await place(byJurisdiction("Portugal", sender: "EDP Comercial"), sender: 7, in: legacy).folderCode == "F2",
                "a folder holding only this sender's documents is its folder, whoever made it")
        let empty = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [portugal, folder(2, "MEO", in: portugal, kind: .sender, logic: Self.logic)])
        #expect(try await place(byJurisdiction("Portugal", sender: "MEO"), sender: nil, in: empty).folderCode == "F2",
                "an empty folder of that name is free for a sender the app does not know yet")
    }

    @Test func aTopicThatMayBeAFolderBesideItIsChosenAmongTheMostAlikeAFewTimesAtMost() async throws {
        let home = folder(1, "Home")
        let utilities = folder(2, "Utilities", in: home)
        let rent = folder(3, "Rent", in: home)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [home, utilities, rent])
        let limits = config.classification.placementGuard
        let between = Float((limits.offerAbove + limits.duplicateAbove) / 2)
        let names: [String: [Float]] = ["Home": [0, 0, 1], "Utilities": [1, 0, 0], "Rent": [0, 1, 0],
                                        "Utility Bills": VectorCodec.normalized([between, (1 - between * between).squareRoot(), 0]),
                                        "Garden": [0.1, 0.1, 0.99]]
        let utilitiesPicked = StubJudge(.named("Utilities"))
        let same = try await place(levels("Home", "Utility Bills"), in: taxonomy, vectors: names, judge: utilitiesPicked)
        let asked = await utilitiesPicked.asked
        #expect(same.folderCode == "F2" && asked == [["Utility Bills", "Utilities, Rent", "Home"]],
                "every folder beside it alike enough is offered in one question, the most alike first")
        let rentPicked = try await place(levels("Home", "Utility Bills"), in: taxonomy, vectors: names, judge: StubJudge(.named("Rent")))
        #expect(rentPicked.folderCode == "F3", "the model may pick a folder other than the one most alike by embedding")
        for answer in [StubJudge.Answer.none, .unsure] {
            let apart = try await place(levels("Home", "Utility Bills"), in: taxonomy, vectors: names, judge: StubJudge(answer))
            #expect(apart.folderCode == nil && apart.newFolder?.levels.map(\.name) == ["Utility Bills"],
                    "none of them, or unsure, keeps it apart: \(answer)")
        }
        let unasked = StubJudge(.first)
        _ = try await place(levels("Home", "Garden"), in: taxonomy, vectors: names, judge: unasked)
        #expect(await unasked.asked.isEmpty, "a name nowhere near an existing one is not put to the judge")
        let deep = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [folder(1, "A"), folder(2, "B", in: folder(1, "A")),
                                                                              folder(3, "C", in: folder(2, "B", in: folder(1, "A")))])
        let close = VectorCodec.normalized([between, (1 - between * between).squareRoot()])
        let vectors: [String: [Float]] = ["A": [1, 0], "B": [1, 0], "C": [1, 0], "A2": close, "B2": close, "C2": close]
        let counted = StubJudge(.first)
        let capped = try await place(levels("A2", "B2", "C2"), in: deep, vectors: vectors, judge: counted)
        #expect(await counted.asked.count == limits.maxJudgements, "a document is put to the judge a few times at most")
        #expect(capped.newFolder?.parentCode == "F2" && capped.newFolder?.levels.map(\.name) == ["C2"],
                "past the last question, the rest of the path is new inside the folders chosen so far")
    }

    @Test func onlyTheMostAlikeFoldersAreOfferedAtOnce() async throws {
        let home = folder(1, "Home")
        let many = (2...8).map { folder(Int64($0), "Topic \($0)", in: home) }
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [home] + many)
        let limits = config.classification.placementGuard
        var vectors: [String: [Float]] = ["Home": alike(0, axis: 7, dimensions: 16), "Bills": alike(1, axis: 1, dimensions: 16)]
        for (index, folder) in many.enumerated() {
            vectors[folder.name] = alike(Float(limits.offerAbove) + 0.01 * Float(index + 1), axis: index + 2, dimensions: 16)
        }
        let judge = StubJudge(.none)
        _ = try await place(levels("Home", "Bills"), in: taxonomy, vectors: vectors, judge: judge)
        let offered = try #require(await judge.asked.first)[1].components(separatedBy: ", ")
        #expect(offered == many.reversed().prefix(limits.choices).map(\.name),
                "a question offers the few folders most alike, the most alike first, however many are alike enough")
    }

    @Test func foldersAreOfferedByTheirNamesAndDescriptionsTogether() throws {
        let level = FolderLevel(name: "Money", description: "Money matters.", kind: .topic)
        let finance = folder(2, "Finanças", description: "Impostos.")
        let expenses = folder(3, "Household Expenses", description: "Bills.")
        let mixed = folder(4, "Finance Misc", description: "Other.")
        let travel = folder(5, "Travel", description: "Trips.")
        let described = { (folder: TaxonomyFolder) in PlacementGuard.described(folder.name, folder.description) }
        let names: [String: [Float]] = ["Money": alike(1, axis: 1), finance.name: alike(0.8, axis: 2), expenses.name: alike(0.3, axis: 3),
                                        mixed.name: alike(0.65, axis: 4), travel.name: alike(0.2, axis: 5)]
        let texts: [String: [Float]] = [PlacementGuard.described(level.name, level.description): alike(1, axis: 1),
                                        described(finance): alike(0.3, axis: 2), described(expenses): alike(0.8, axis: 3),
                                        described(mixed): alike(0.65, axis: 4), described(travel): alike(0.2, axis: 5)]
        let guardian = PlacementGuard(config: config.classification.placementGuard)
        let offered = guardian.offers([finance, expenses, mixed, travel], to: level, vectors: names.merging(texts) { a, _ in a })
        #expect(offered.map(\.folder.name) == ["Finanças", "Household Expenses", "Finance Misc"],
                "a folder alike by name (another language) and one alike by what it holds are both offered, first")
        #expect(!guardian.offers([finance, expenses, mixed, travel], to: level, vectors: names).contains { $0.folder.name == "Household Expenses" },
                "by names alone, the folder that holds the same things under another name is missed")
        let portugal = FolderLevel(name: "Taxes (Portugal)", description: "Portuguese taxes.", kind: .topic)
        let russia = folder(6, "Taxes (Russia)", description: "Russian taxes.")
        let same: [String: [Float]] = [portugal.name: alike(1, axis: 1), russia.name: alike(1, axis: 1),
                                       PlacementGuard.described(portugal.name, portugal.description): alike(1, axis: 1),
                                       described(russia): alike(1, axis: 1)]
        #expect(guardian.offers([russia], to: portugal, vectors: same).isEmpty, "another country's folder is never offered")
    }

    @Test func aFolderChoiceIsAnOfferedNumberNoneOrUnsure() throws {
        #expect(try AnswerValidator.folderChoice(#"{"choice":"2"}"#, options: 3) == .option(1))
        #expect(try AnswerValidator.folderChoice("<think>hm</think>" + #"{"choice":" None "}"#, options: 3) == .none)
        #expect(try AnswerValidator.folderChoice(#"{"choice":"unsure"}"#, options: 3) == .unsure)
        for outside in ["0", "4", "-1", "Utilities", ""] {
            #expect(throws: AnswerValidationError.self, "a folder that was not offered is never taken: “\(outside)”") {
                try AnswerValidator.folderChoice(#"{"choice":"\#(outside)"}"#, options: 3)
            }
        }
        #expect(throws: AnswerValidationError.self, "an answer that is not the schema's object is refused") {
            try AnswerValidator.folderChoice("yes", options: 3)
        }
        #expect(ClassificationSchema.folderChoice(options: 2)["properties"]?["choice"]?["enum"]
                    == .array([.string("1"), .string("2"), .string("none"), .string("unsure")]),
                "the schema lets the model answer only with a number offered, none or unsure")
        #expect(PromptBuilder.judgedDocument(title: "Extrato agosto", type: .statement, sender: "Millennium BCP")
                    == "Title: Extrato agosto\nType: statement\nFrom: Millennium BCP")
        #expect(PromptBuilder.judgedDocument(title: "Scan 12", type: .other, sender: nil) == "Title: Scan 12",
                "what the document is not known to be is left out rather than guessed")
    }

    @Test func aPathIntoTheAppsOwnFoldersLeadsNowhere() async throws {
        let system = folder(1, "System", origin: .system)
        let review = folder(2, "Needs review", in: system, origin: .system, role: .needsReview)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [system, review])
        let placement = try await place(levels("System", "Bills"), in: taxonomy)
        #expect(placement.folderCode == nil && placement.newFolder == nil, "a folder of the user's is never made inside the system area")
    }

    @Test func calibrationBands() {
        let calibrator = Calibrator(config: config.calibration)
        let thresholds = Thresholds(auto: 0.85, review: 0.5)
        let candidates = CandidateSet(ranked: [FolderCandidate(code: "11", similarity: 0.8, knnVote: 2, score: 1),
                                               FolderCandidate(code: "12", similarity: 0.2, knnVote: 0, score: 0)],
                                      neighbors: [], knnShare: ["11": 1], usedMemories: true)
        let good = ExtractedContentSummary(Fixtures.content("a.pdf", text: "x"))
        func run(_ llm: Double, _ code: String?, new: Bool = false, ideal: Double? = 0.9, content: ExtractedContentSummary) -> ConfidenceReport {
            calibrator.calibrate(CalibrationInput(llmConfidence: llm, chosenCode: code, isNewFolder: new, idealSimilarity: ideal,
                                                  candidates: candidates, ruleHit: nil, ruleAgrees: false, content: content),
                                 thresholds: thresholds)
        }
        #expect(run(0.95, "11", content: good).band == .auto)
        #expect(run(0.95, "11", ideal: 0.5, content: good).final < run(0.95, "11", content: good).final)
        #expect(run(0.6, "12", ideal: 0.5, content: good).band == .review)
        #expect(run(0.95, nil, new: true, content: good).final == 0.95 * config.calibration.newFolderConfidenceScale)
        var metadataOnly = good
        metadataOnly.textOrigin = .metadataOnly
        #expect(run(1, "11", content: metadataOnly).final <= config.calibration.metadataOnlyCap)
    }
}

/// Answers every question the same way and remembers what it was asked: the level, the folders offered, and where.
actor StubJudge: FolderJudge {
    enum Answer: Sendable {
        /// The folder offered under this name, or none of them when it is not offered.
        case named(String)
        /// The folder offered first.
        case first
        case none
        case unsure
    }

    let answer: Answer
    private(set) var asked: [[String]] = []

    init(_ answer: Answer = .unsure) { self.answer = answer }

    func choose(_ level: FolderLevel, among candidates: [TaxonomyFolder], inside place: String) async throws -> FolderChoice {
        asked.append([level.name, candidates.map(\.name).joined(separator: ", "), place])
        switch answer {
        case let .named(name): return candidates.first { $0.name == name }.map(FolderChoice.folder) ?? .none
        case .first: return candidates.first.map(FolderChoice.folder) ?? .none
        case .none: return .none
        case .unsure: return .unsure
        }
    }
}
