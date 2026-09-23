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
        let engine = RuleEngine(rules: [rule], config: config.classification)
        let c = Fixtures.content("f.pdf", text: Fixtures.edpText, keys: [StableKey(kind: .ptNIF, value: "503504564")])
        #expect(engine.evaluateBeforeModel(c, matches: [], detectedType: nil).0?.rule.id == 7)
        let miss = Fixtures.content("f.txt", text: Fixtures.edpText, keys: [StableKey(kind: .ptNIF, value: "503504564")])
        #expect(engine.evaluateBeforeModel(miss, matches: [], detectedType: nil).0 == nil)
    }

    @Test func typeConditionsNeedAnEstimateBeforeTheModel() {
        let rule = FilingRule(id: 8, name: "ids", priority: 10, origin: .induced, predicates: [.documentType(.idDocument)],
                              action: RuleAction(folderID: 1, folderCode: "11"))
        let engine = RuleEngine(rules: [rule], config: config.classification)
        let c = Fixtures.content("p.pdf", text: "Passport")
        #expect(engine.evaluateBeforeModel(c, matches: [], detectedType: nil).0 == nil)
        #expect(engine.evaluateBeforeModel(c, matches: [], detectedType: .idDocument).0 != nil)
        #expect(engine.evaluateAfterModel(c, matches: [], documentType: .idDocument).0 != nil)
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

    func validator() -> AnswerValidator {
        let area = TaxonomyFolder(id: 1, code: "10-19", name: "Home", parentCode: nil, relativePath: "10-19 Home", kind: .area)
        let folder = TaxonomyFolder(id: 2, code: "11", name: "Utilities", parentCode: "10-19", relativePath: "10-19 Home/11 Utilities",
                                    kind: .category)
        return AnswerValidator(taxonomy: TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [area, folder]),
                               config: config.classification, entities: config.entities, languages: config.extraction.languages)
    }

    @Test func existingFolderAnswerIsNormalised() throws {
        let raw = "<think>hmm</think>" + Fixtures.answer(folder: "11", confidence: 1.7)
        let v = try validator().validate(raw)
        #expect(v.folderCode == "11" && v.newFolder == nil)
        #expect(v.ideal.name == "Utilities" && v.ideal.newAreaName == "Home" && v.ideal.yearSubfolders)
        #expect(v.documentType == .invoice && v.documentDate == "2026-07-05")
        #expect(v.tags == ["energy"] && v.confidence == 1)
        #expect(v.raw.fileName == "2026-07-05 EDP - Fatura eletricidade junho")
    }

    @Test func newFolderComesFromTheIdealHome() throws {
        let inArea = try validator().validate(Fixtures.answer(folder: "NEW", newArea: "10-19", idealCategory: "Internet and Phone"))
        #expect(inArea.newFolder?.areaCode == "10-19" && inArea.newFolder?.name == "Internet and Phone")
        #expect(inArea.newFolder?.newAreaName == nil)
        let newArea = try validator().validate(Fixtures.answer(folder: "NEW", newArea: "NEW", idealArea: "Health",
                                                               idealCategory: "Medical Records"))
        #expect(newArea.newFolder?.areaCode == nil && newArea.newFolder?.newAreaName == "Health")
        #expect(newArea.newFolder?.yearSubfolders == true)
    }

    @Test func namesEchoedWithTheirCodesAreTheFoldersTheyName() throws {
        let area = try validator().validate(Fixtures.answer(folder: "NEW", idealArea: "10-19 Home", idealCategory: "Internet and Phone"))
        #expect(area.newFolder?.areaCode == "10-19" && area.newFolder?.newAreaName == nil,
                "an existing area named as its directory is that area, never a new one with the code in its name")
        let unknown = try validator().validate(Fixtures.answer(folder: "NEW", newArea: "NEW", idealArea: "60-69 Travel",
                                                               idealCategory: "Trips"))
        #expect(unknown.newFolder?.newAreaName == "Travel" && unknown.newFolder?.areaCode == nil,
                "a code that names no area is dropped from the name")
        let category = try validator().validate(Fixtures.answer(folder: "11", idealArea: "10-19 Home", idealCategory: "11 Utilities"))
        #expect(category.ideal.name == "Utilities" && category.ideal.areaCode == "10-19" && category.folderCode == "11")
        let digits = try validator().validate(Fixtures.answer(folder: "NEW", newArea: "NEW", idealArea: "Money",
                                                              idealCategory: "2025 Taxes"))
        #expect(digits.newFolder?.name == "2025 Taxes", "a name that starts with digits keeps them")
    }

    @Test func invalidAnswersAreRejected() {
        #expect(throws: AnswerValidationError.self) { try validator().validate(Fixtures.answer(folder: "99")) }
        #expect(throws: AnswerValidationError.self) { try validator().validate(Fixtures.answer(folder: "NEW", newArea: "77-79")) }
        #expect(throws: AnswerValidationError.self) { try validator().validate(Fixtures.answer(folder: "NEW", idealCategory: "")) }
        #expect(throws: AnswerValidationError.self) { try validator().validate(Fixtures.answer(folder: "11", idealCategory: "A/B")) }
        #expect(throws: AnswerValidationError.self) { try validator().validate("not json") }
        #expect(throws: AnswerValidationError.self) {
            try validator().validate(Fixtures.answer(folder: "NEW", newArea: "NEW", idealArea: "Health", idealCategory: "medical-report"))
        }
        #expect(throws: AnswerValidationError.self) {
            try validator().validate(Fixtures.answer(folder: "NEW", newArea: "NEW", idealArea: "Money", idealCategory: "money"))
        }
    }

    @Test func guardReplacesMismatchesAndReusesDuplicates() throws {
        let area = TaxonomyFolder(id: 1, code: "10-19", name: "Home", parentCode: nil, relativePath: "10-19 Home", kind: .area)
        let utilities = TaxonomyFolder(id: 2, code: "11", name: "Utilities", parentCode: "10-19", relativePath: "10-19 Home/11 Utilities",
                                       kind: .category)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [area, utilities])
        let guardrail = PlacementGuard(config: config.classification.placementGuard)
        let tax = try validator().validate(Fixtures.answer(folder: "11", idealArea: "Money", idealCategory: "Taxes (Portugal)"))
        let names: [String: [Float]] = ["Taxes (Portugal)": [1, 0, 0], "Utilities": [0, 1, 0], "Home": [0, 1, 0], "Money": [0, 0, 1],
                                        "Household Utilities": VectorCodec.normalized([0.1, 1, 0])]
        let mismatch = guardrail.review(tax, taxonomy: taxonomy, names: names)
        #expect(mismatch.folderCode == nil && mismatch.newFolder?.name == "Taxes (Portugal)" && mismatch.newFolder?.newAreaName == "Money")
        let homeTax = try validator().validate(Fixtures.answer(folder: "11", idealArea: "Home", idealCategory: "Taxes (Portugal)"))
        #expect(guardrail.review(homeTax, taxonomy: taxonomy, names: names).newFolder?.areaCode == "10-19")
        let taxes = TaxonomyFolder(id: 3, code: "12", name: "Taxes (Portugal)", parentCode: "10-19",
                                   relativePath: "10-19 Home/12 Taxes (Portugal)", kind: .category)
        let withTaxes = TaxonomySnapshot(version: 2, rootPath: "/tmp", folders: [area, utilities, taxes])
        let wrongArea = guardrail.review(tax, taxonomy: withTaxes, names: names)
        #expect(wrongArea.folderCode == nil && wrongArea.newFolder?.newAreaName == "Money",
                "the same topic in an area unlike the ideal one is not its home")
        let money = TaxonomyFolder(id: 4, code: "20-29", name: "Money", parentCode: nil, relativePath: "20-29 Money", kind: .area)
        let moneyTaxes = TaxonomyFolder(id: 5, code: "21", name: "Taxes (Portugal)", parentCode: "20-29",
                                        relativePath: "20-29 Money/21 Taxes (Portugal)", kind: .category)
        let withMoney = TaxonomySnapshot(version: 3, rootPath: "/tmp", folders: [area, utilities, taxes, money, moneyTaxes])
        let existingIdeal = guardrail.review(tax, taxonomy: withMoney, names: names)
        #expect(existingIdeal.folderCode == "21" && existingIdeal.newFolder == nil)
        let duplicate = try validator().validate(Fixtures.answer(folder: "NEW", newArea: "NEW", idealCategory: "Household Utilities"))
        let reused = guardrail.review(duplicate, taxonomy: taxonomy, names: names)
        #expect(reused.folderCode == "11" && reused.newFolder == nil)
        let keep = guardrail.review(try validator().validate(Fixtures.answer(folder: "11")), taxonomy: taxonomy, names: names)
        #expect(keep.folderCode == "11" && keep.idealSimilarity == 1)
    }

    @Test func differentQualifiersAreDifferentCategories() throws {
        let area = TaxonomyFolder(id: 1, code: "10-19", name: "Money", parentCode: nil, relativePath: "10-19 Money", kind: .area)
        let pt = TaxonomyFolder(id: 2, code: "11", name: "Taxes (Portugal)", parentCode: "10-19", relativePath: "10-19 Money/11 Taxes (Portugal)",
                                kind: .category)
        let taxonomy = TaxonomySnapshot(version: 1, rootPath: "/tmp", folders: [area, pt])
        let v: [Float] = [1, 0]
        let names: [String: [Float]] = ["Taxes (Russia)": v, "Taxes (Portugal)": v, "Money": v]
        let guardrail = PlacementGuard(config: config.classification.placementGuard)
        let wrongCountry = guardrail.review(try validator().validate(Fixtures.answer(folder: "11", idealArea: "Money",
                                                                                     idealCategory: "Taxes (Russia)")),
                                            taxonomy: taxonomy, names: names)
        #expect(wrongCountry.folderCode == nil && wrongCountry.newFolder?.name == "Taxes (Russia)")
        let proposed = guardrail.review(try validator().validate(Fixtures.answer(folder: "NEW", newArea: "NEW", idealArea: "Money",
                                                                                 idealCategory: "Taxes (Russia)")),
                                        taxonomy: taxonomy, names: names)
        #expect(proposed.newFolder?.name == "Taxes (Russia)")
        #expect(PlacementGuard.qualifier("Impostos (Portugal) ") == "portugal")
    }

    @Test func calibrationBands() {
        let calibrator = Calibrator(config: config.calibration)
        let thresholds = Thresholds(auto: 0.85, review: 0.5)
        let candidates = CandidateSet(ranked: [FolderCandidate(code: "11", similarity: 0.8, knnVote: 2, score: 1),
                                               FolderCandidate(code: "12", similarity: 0.2, knnVote: 0, score: 0)],
                                      memories: [], knnShare: ["11": 1], usedMemories: true)
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
