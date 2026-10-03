@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// How alike two labels are written (`LabelSimilarity`, docs/how-it-works.md#keeping-labels-one-vocabulary): numbers
/// first, as written and in order, then the writing of the words, then Jaro-Winkler; and every place that takes two
/// labels for one, from a reading to the sidebar, following the same rule.
@Suite struct LabelSimilarityTests {
    static func label(_ kind: LabelKind, _ value: String) -> DocumentLabel { LabelVocabularyTests.label(kind, value) }

    static func consolidator(rules: [LabelRule] = [], vocabulary: [(LabelKind, String, Int)] = []) throws -> LabelConsolidator {
        try LabelVocabularyTests.consolidator(rules: rules, vocabulary: vocabulary)
    }

    static func rule(_ id: Int64, _ kind: LabelKind, _ value: String, _ action: LabelRuleAction, _ target: String? = nil) -> LabelRule {
        LabelVocabularyTests.rule(id, kind, value, action, target)
    }

    // MARK: How alike labels are written

    @Test func labelsWrittenTheSameButForCaseAccentsPunctuationAndWordOrderAreOne() {
        #expect(LabelSimilarity.similarity("EDP-Comercial, S.A.", "edp comercial SA") == 1, "punctuation and case")
        #expect(LabelSimilarity.similarity("Silva, Maria", "Maria Silva") == 1, "word order")
        #expect(LabelSimilarity.similarity("Autoridade Tributária", "AUTORIDADE TRIBUTARIA") == 1, "accents")
        #expect(LabelSimilarity.sameWriting("Ｅｄｐ", "EDP"), "full-width letters")
        #expect(!LabelSimilarity.sameWriting("EDP", "EDP Comercial"), "a longer name is another writing")
    }

    @Test func aLabelIsOfferedTheMostAlikeToMergeIntoTheMostUsedOfThoseAsAlikeFirst() {
        // The others in the order the archive uses them, the most used first.
        let others = ["Galp", "EDP Comercial", "EDP", "EDP Comercial SA", "Iberdrola"]
        let offered = LabelSimilarity.mostAlike(to: "EDP Comercail", among: others + ["EDP Comercail"], limit: 3)
        #expect(offered.first == "EDP Comercial" && offered.count == 3 && !offered.contains("EDP Comercail"),
                "the most alike first, at most as many as asked, and never the label itself: \(offered)")
        #expect(LabelSimilarity.mostAlike(to: "x", among: ["EDP", "MEO"], limit: 5) == ["EDP", "MEO"],
                "of those as alike, the most used first")
        #expect(LabelSimilarity.mostAlike(to: "EDP", among: others, limit: 0).isEmpty, "and none when none are asked for")
    }

    @Test func labelsWhoseNumbersDifferAreNeverAlike() {
        #expect(LabelSimilarity.similarity("invoice FT 2026/926804564", "invoice FT 2026/926804565") == 0, "two invoices a digit apart stay two")
        #expect(LabelSimilarity.similarity("apartment Rua das Flores 12", "apartment Rua das Flores 14") == 0,
                "a number tells one address, account or invoice from the next")
    }

    /// The same digits, split into other numbers or put in another order: another invoice, another address.
    static let sameDigitsOtherNumbers = [("FT 1/23", "FT 12/3"), ("Rua das Flores 12, 3", "Rua das Flores 3, 12"),
                                         ("invoice 2026/11", "invoice 20/2611")]

    @Test(arguments: sameDigitsOtherNumbers)
    func theSameDigitsInOtherNumbersAreOtherLabels(_ a: String, _ b: String) {
        #expect(LabelSimilarity.similarity(a, b) == 0, "\(a) and \(b) are other numbers, so never alike")
        #expect(!LabelSimilarity.sameWriting(a, b), "\(a) is not \(b) written another way, so no rule about one concerns the other")
    }

    /// Each of `sameDigitsOtherNumbers` written another way, its numbers as they were.
    static let sameNumbersWrittenOtherwise = [("FT 1/23", "ft 1-23"), ("Rua das Flores 12, 3", "rua das flores 12-3"),
                                              ("invoice 2026/11", "Invoice 2026-11"), ("FT2026/11", "FT 2026/11")]

    @Test(arguments: sameNumbersWrittenOtherwise)
    func theSameNumbersWrittenOtherwiseAreOneLabel(_ a: String, _ b: String) {
        #expect(LabelSimilarity.sameWriting(a, b) && LabelSimilarity.similarity(a, b) == 1,
                "\(a) and \(b) differ only in case, punctuation, spacing or the order of their words")
    }

    @Test func aLabelInUseIsNeverGivenToAnotherNumberWithTheSameDigits() throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .reference, "invoice 2026/11", .merge, "Invoice 2026-11")],
                                      vocabulary: [(.reference, "FT 12/3", 4), (.object, "Rua das Flores 3, 12", 2)])
        #expect(c.consolidate([Self.label(.reference, "FT 1/23"), Self.label(.object, "Rua das Flores 12, 3")]).changes.isEmpty,
                "a reference and an address the archive already has with the same digits stay as the model wrote them")
        #expect(c.consolidate([Self.label(.reference, "invoice 20/2611")]).changes.isEmpty,
                "and the user's rule about one invoice is not followed for another")
    }

    /// One identifier written with spaces between its groups and without, as it is printed and as it is typed: an IBAN
    /// on paper and electronically (ISO 13616), a tax number, a phone number, a reference with a letter among its digits.
    static let spacedOtherwise = [("account PT50 0002 0123 1234 5678 9015 4", "account PT50000201231234567890154"),
                                  ("NIF 123 456 789", "NIF 123456789"), ("phone +351 912 345 678", "phone +351912345678"),
                                  ("26 69 A 244167 67", "2669A24416767")]

    @Test(arguments: spacedOtherwise)
    func oneIdentifierSpacedOtherwiseIsOneLabel(_ a: String, _ b: String) {
        #expect(LabelSimilarity.sameWriting(a, b) && LabelSimilarity.similarity(a, b) == 1,
                "\(a) and \(b) differ only in the spaces between the groups of one number, so they are one label")
    }

    /// The same digits, bounded by punctuation in one and not, or not all, in the other: perhaps one number written two
    /// ways, perhaps two numbers, which only the user can tell.
    static let groupedOtherwise = [("V/2026/532774", "V2026532774"), ("NIF 123.456.789", "NIF 123456789"),
                                   ("phone 912-345-678", "phone 912 345 678"), ("FT 1/2/3", "FT 12/3")]

    /// Thresholds at their ends: every label merged into the one in use, and only labels written the same way offered.
    static func atTheEnds(_ config: LabelVocabularyConfig) -> LabelVocabularyConfig {
        var config = config
        for kind in config.kinds.keys {
            config.kinds[kind]?.mergeSimilarity = 0
            config.kinds[kind]?.suggestSimilarity = 1
        }
        return config
    }

    @Test(arguments: groupedOtherwise)
    func theSameDigitsGroupedOtherwiseAreOfferedForEveryKindAndNeverMerged(_ a: String, _ b: String) async throws {
        #expect(!LabelSimilarity.sameWriting(a, b) && LabelSimilarity.similarity(a, b) == 0,
                "\(a) and \(b) are not one writing, and their numbers differ: no degree of likeness merges them")
        let bundled = try PipelineConfig.bundledDefaults().labels.vocabulary
        for config in [bundled, Self.atTheEnds(bundled)] {
            for kind in config.kinds.keys {
                let reading = LabelConsolidator(config: config, rules: [], vocabulary: LabelVocabularyTests.vocabulary([(kind, a, 3)]))
                #expect(reading.consolidate([Self.label(kind, b)]).changes.isEmpty, "a \(kind.rawValue) is never merged with the other on its own")
                let both = LabelConsolidator(config: config, rules: [], vocabulary: LabelVocabularyTests.vocabulary([(kind, a, 3), (kind, b, 1)]))
                #expect(both.suggestions() == [LabelSuggestion(kind: kind, value: b, into: a, similarity: 1, reason: .sameDigitsGroupedOtherwise)],
                        "but offered to the user as a \(kind.rawValue), saying why, whatever the kind's thresholds")
            }
        }
        let memo = LookAlikeMemo()
        func suggestions(_ c: LabelConsolidator) async throws -> [LabelSuggestion] {
            try await c.suggestions(by: memo, comparing: LabelSimilarity.lookAlike(_:_:atLeast:))
        }
        for kind in bundled.kinds.keys {
            _ = try await suggestions(LabelConsolidator(config: bundled, rules: [], vocabulary: LabelVocabularyTests.vocabulary([(kind, a, 3)])))
            let added = try await suggestions(LabelConsolidator(config: bundled, rules: [],
                                                                vocabulary: LabelVocabularyTests.vocabulary([(kind, a, 3), (kind, b, 1)])))
            #expect(added.map(\.reason) == [.sameDigitsGroupedOtherwise], "and so when the other comes, as the app keeps them up to date")
        }
    }

    /// The same letters and digits, the letters moved around the digits: another car, invoice, serial number or company.
    static let lettersMovedAroundDigits = [("car AB12CD", "car CD12AB"), ("invoice A1B2", "invoice B1A2"),
                                           ("serial AB12CD34", "serial CD12AB34"), ("3M Portugal", "M3 Portugal")]

    @Test(arguments: lettersMovedAroundDigits)
    func lettersMovedAroundDigitsAreAnotherLabel(_ a: String, _ b: String) {
        #expect(!LabelSimilarity.sameWriting(a, b) && LabelSimilarity.similarity(a, b) < 1,
                "\(a) is not \(b) written another way: a word is compared as it is written, letters and digits in their order")
    }

    /// The same words and number, words moved across the number: another car, plates written as Portugal's have been
    /// since 2020 (`AA-00-AA`), spaced or dashed; and an address written from its other end.
    static let wordsMovedAcrossANumber = [("car AB 12 CD", "car CD 12 AB"), ("car AA-12-BB", "car BB-12-AA"),
                                          ("12 Rua das Flores", "Rua das Flores 12")]

    @Test(arguments: wordsMovedAcrossANumber)
    func wordsMovedAcrossANumberAreAnotherWriting(_ a: String, _ b: String) {
        #expect(!LabelSimilarity.sameWriting(a, b) && LabelSimilarity.similarity(a, b) < 1,
                "\(a) is not \(b) written another way: words change places between two numbers, never across one")
    }

    /// Words reordered between a number and the label's end, or between two numbers.
    static let wordsReorderedBetweenNumbers = [("EDP Comercial 12", "Comercial EDP 12"),
                                               ("apartment Rua das Flores 12, 3", "Rua das Flores apartment 12, 3"),
                                               ("invoice FT 2026/11 paid", "FT invoice 2026/11 paid")]

    @Test(arguments: wordsReorderedBetweenNumbers)
    func wordsReorderedBetweenNumbersAreOneLabel(_ a: String, _ b: String) {
        #expect(LabelSimilarity.sameWriting(a, b) && LabelSimilarity.similarity(a, b) == 1,
                "\(a) and \(b) differ only in the order of words that no number separates")
    }

    /// Words reordered before an identifier, and the identifier spaced otherwise, both at once.
    static let reorderedAndSpacedOtherwise = [("account Santander PT50 0002 0123", "Santander account PT5000020123"),
                                              ("phone Maria 912 345 678", "Maria phone 912345678")]

    @Test(arguments: reorderedAndSpacedOtherwise)
    func wordsReorderedAndAnIdentifierSpacedOtherwiseAreOneLabel(_ a: String, _ b: String) async throws {
        #expect(LabelSimilarity.sameWriting(a, b) && LabelSimilarity.similarity(a, b) == 1,
                "\(a) and \(b) differ only in word order and in the spaces within one number, each of which is one writing")
        let c = try Self.consolidator(rules: [Self.rule(1, .object, a, .merge, "the \(a)")], vocabulary: [(.object, a, 3)])
        #expect(c.consolidate([Self.label(.object, b)]).labels == [Self.label(.object, "the \(a)")], "the user's rule about one is the other's")
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: ["a.txt": [Self.label(.object, a)], "b.txt": [Self.label(.object, b)]]))
        defer { h.env.cleanup() }
        let first = try #require(try await h.ingest("a.txt", text: "A statement").id)
        let second = try #require(try await h.ingest("b.txt", text: "Another statement").id)
        #expect(try await h.services.documents.document(id: second)?.labels?.values(.object) == [a], "a reading writes it as the archive does")
        let narrowed = try await h.services.documents.list(DocumentFilter(labels: [Self.label(.object, b)]), limit: 10).compactMap(\.id).sorted()
        #expect(narrowed == [first, second], "the sidebar narrows either writing to both documents")
        await #expect(throws: LabelError.sameLabel(.object, a), "and the two cannot be kept apart, being one") {
            try await h.labels.keepApart(Self.label(.object, a), from: b)
        }
        #expect(try await h.labels.ignore(Self.label(.object, b)).documents == [first, second], "removing one writing removes both")
    }

    /// Two cars whose plates hold the same letters and digits, the letters moved around the digits: glued to them, spaced
    /// from them or dashed.
    static let twoCars = [("car AB12CD", "car CD12AB"), ("car AB 12 CD", "car CD 12 AB"), ("car AA-12-BB", "car BB-12-AA")]

    @Test(arguments: twoCars)
    func aCarsPlateIsNeverTakenForAnotherInUseNorFollowsItsRules(_ a: String, _ b: String) throws {
        let c = try Self.consolidator(rules: [Self.rule(1, .object, a, .merge, "plate \(a)")], vocabulary: [(.object, a, 3)])
        #expect(c.consolidate([Self.label(.object, b)]).changes.isEmpty,
                "another car stays as the model wrote it: neither the plate in use nor the user's rule about it is taken for it")
    }

    /// Two documents about the two cars `a` and `b`.
    private func cars(_ a: String, _ b: String) async throws -> (Harness, a: Int64, b: Int64) {
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: ["a.txt": [Self.label(.object, a)], "b.txt": [Self.label(.object, b)]]))
        let first = try #require(try await h.ingest("a.txt", text: "Insurance of a car").id)
        let second = try #require(try await h.ingest("b.txt", text: "Insurance of another car").id)
        return (h, first, second)
    }

    @Test(arguments: twoCars)
    func everyDecisionAboutACarsPlateLeavesTheOtherCarsAsItIs(_ a: String, _ b: String) async throws {
        let (h, first, second) = try await cars(a, b)
        defer { h.env.cleanup() }
        func objects(_ id: Int64) async throws -> [String] { try #require(try await h.services.documents.document(id: id)?.labels).values(.object) }
        #expect(try await objects(second) == [b], "the second car is filed with its own plate, not the first car's")
        let ids = { (labels: [DocumentLabel]) in try await h.services.documents.list(DocumentFilter(labels: labels), limit: 10).compactMap(\.id) }
        #expect(try await ids([Self.label(.object, a)]) == [first], "the sidebar narrows a label down to its own documents")
        try await h.labels.keepApart(Self.label(.object, a), from: b)
        let merged = try await h.labels.merge(Self.label(.object, a), into: "plate \(a)")
        let afterMerge = try await objects(second)
        #expect(merged.documents == [first] && afterMerge == [b], "a merge relabels the one car only")
        let ignored = try await h.labels.ignore(Self.label(.object, "plate \(a)"))
        let afterIgnoring = try await objects(second)
        #expect(ignored.documents == [first] && afterIgnoring == [b], "and so does removing it everywhere")
    }

    @Test func otherwiseTheyAreComparedByJaroWinklerAsPublished() {
        // The examples in Winkler 1990, which defines the measure (docs/organizing-principles-sources.md).
        #expect(abs(LabelSimilarity.similarity("MARTHA", "MARHTA") - 0.961) < 0.001, "Winkler's MARTHA/MARHTA is 0.961")
        #expect(abs(LabelSimilarity.similarity("DWAYNE", "DUANE") - 0.840) < 0.001, "Winkler's DWAYNE/DUANE is 0.840")
        #expect(abs(LabelSimilarity.similarity("DIXON", "DICKSONX") - 0.813) < 0.001, "Winkler's DIXON/DICKSONX is 0.813")
        #expect(LabelSimilarity.similarity("electricity", "electricty") >= 0.96, "a typo is nearly the same label")
        #expect(LabelSimilarity.similarity("income tax", "property tax") < 0.85, "a different subject is not")
    }

    @Test func theBoundFromLengthsIsNeverBelowTheSimilarity() {
        let words = ["EDP", "EDP Comercial", "electricity", "electricty", "Maria Silva", "Mario Silva", "a", "income tax",
                     "Autoridade Tributária", "tax"]
        for a in words {
            for b in words {
                let (x, y) = (LabelSimilarity.Key(a), LabelSimilarity.Key(b))
                #expect(LabelSimilarity.bound(x, y) >= LabelSimilarity.similarity(x, y) - 1e-9, "skipping \(a)/\(b) would lose a match")
            }
        }
    }
}
