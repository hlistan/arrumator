@testable import ArrumatorClassify
import ArrumatorCore
import Foundation
import Testing

/// What a request's words ask for: to arrange the documents, or one more of the alternatives it lists.
extension SearchInterpreterTests {
    /// A quote that holds what labels of other kinds ask for, as an inferred sender quoted by "квитанции за
    /// электричество" holds the type's "квитанции" and the topic's "электричество", asked for that sender alone and left
    /// out every bill of another (QA 2026-10-04, TSK-1 re-check): it goes back to the model, named with what it holds,
    /// and the type, topic and date stand; given again, it is the model's answer.
    @Test func aLabelWhoseQuoteHoldsWhatLabelsOfOtherKindsAskForGoesBackToTheModel() throws {
        let request = "квитанции за электричество 2026 года, по отправителю"
        let broad = try Self.answer([
            "senders": .array([Self.asked("Мосэнергосбыт", "квитанции за электричество")]), "types": .array([Self.asked("invoice", "квитанции")]),
            "topics": .array([Self.asked("electricity", "электричество")]), "dates": .array([Self.asked("2026", "2026 года")]),
            "group_by": Self.grouped(("sender", "по отправителю")),
        ])
        let sentBack = SentBack()
        let sent = #expect(throws: GuessSentBack<ValidatedSearchPlan>.self, "the sender goes back, named with the labels its quote holds") {
            try Self.validator().validate(broad, request: request, sentBack: sentBack)
        }
        sent?.sent()
        #expect(sent?.problems == [
            "senders: “Мосэнергосбыт” is asked for by “квитанции за электричество”, which holds what types “invoice” (“квитанции”) and "
                + "topics “electricity” (“электричество”) ask for: give it only with the words that ask for it by themselves, or leave it out when none do",
        ])
        let repaired = try Self.validator().validate(Self.answer([
            "senders": .array([]), "types": .array([Self.asked("invoice", "квитанции")]),
            "topics": .array([Self.asked("electricity", "электричество")]), "dates": .array([Self.asked("2026", "2026 года")]),
            "group_by": Self.grouped(("sender", "по отправителю")),
        ]), request: request, sentBack: sentBack)
        #expect(repaired.plan.labels == [DocumentLabel(kind: .type, value: "invoice"), DocumentLabel(kind: .date, value: "2026"),
                                         DocumentLabel(kind: .topic, value: "electricity")] && repaired.plan.grouping == [.sender],
                "the answer without it asks for every electricity bill of 2026, arranged by sender: \(repaired.notes)")
        let again = try Self.validator().validate(broad, request: request, sentBack: sentBack)
        #expect(again.plan.labels.values(.sender) == ["Мосэнергосбыт"]
                    && again.notes.contains("senders: “Мосэнергосбыт” is asked for by “квитанции за электричество”, which holds other labels' words, and is kept as the model gives it again"),
                "given again after being told, it is the model's answer: \(again.notes)")
        let authority = try Self.validator().validate(Self.answer([
            "senders": .array([Self.asked("Autoridade Tributária", "the tax authority"), Self.asked("HMRC", "the tax authority")]),
            "types": .array([]), "dates": .array([]), "topics": .array([Self.asked("income tax", "income tax")]),
            "group_by": Self.grouped(("sender", "by sender")),
        ]), request: "documents from the tax authority in any country about income tax, by sender")
        #expect(authority.plan.labels.values(.sender) == ["Autoridade Tributária", "HMRC"] && authority.plan.labels.values(.topic) == ["income tax"],
                "senders a phrase lists, holding no other label's quote, stand (QA 2026-10-04, TSK-3): \(authority.notes)")
    }

    /// Arranging is not limiting: "по отправителю" ("by sender") asks to arrange the documents by sender, and a sender it
    /// alone grounds would leave out every bill of another (QA 2026-10-04, TSK-1).
    @Test func wordsThatAskToArrangeTheDocumentsGroundNoLabelAndNoWord() throws {
        let request = "квитанции за электричество 2026 года, по отправителю"
        let checked = try Self.validator().validate(Self.answer([
            "senders": .array([Self.asked("Мосэнергосбыт", "по отправителю"), Self.asked("EDP Comercial", "отправителю")]),
            "types": .array([Self.asked("invoice", "квитанции")]), "topics": .array([Self.asked("electricity", "электричество")]),
            "dates": .array([Self.asked("2026", "2026 года")]), "words": Self.strings("по отправителю"),
            "group_by": Self.grouped(("sender", "по отправителю")),
        ]), request: request)
        #expect(checked.plan.labels.values(.sender).isEmpty && checked.plan.words.isEmpty,
                "no sender and no word is asked for by the words that arrange the documents: \(checked.plan)")
        #expect(checked.plan.grouping == [.sender] && checked.plan.labels.values(.type) == ["invoice"]
                    && checked.plan.labels.values(.date) == ["2026"] && checked.plan.labels.values(.topic) == ["electricity"],
                "the documents are arranged by sender, and the rest of the plan stands")
        #expect(checked.notes.contains("senders: “Мосэнергосбыт” is asked for only by words that arrange the documents (“по отправителю”), dropped")
                    && checked.notes.contains("words: “по отправителю” only asks to arrange the documents, dropped"),
                "and the trace says why: \(checked.notes)")
        let named = try Self.validator().validate(Self.answer([
            "senders": .array([Self.asked("EDP Comercial", "EDP")]), "group_by": Self.grouped(("sender", "by sender")),
        ]), request: Self.request)
        #expect(named.plan.labels.values(.sender) == ["EDP Comercial"], "a sender the request names stands beside an arrangement by sender")
        let unquoted = try Self.validator().validate(Self.answer(["group_by": Self.grouped(("sender", "per remetente"))]), request: Self.request)
        #expect(unquoted.plan.labels == Self.edp2025.labels && unquoted.plan.grouping == [.sender], "an arrangement quoting words the request does not have grounds nothing, and leaves nothing out")
    }

    /// A grouping quote that runs over words which limit takes no label of another kind with it: "invoices by sender"
    /// arranges invoices by sender, and asks for invoices (review of 2026-10-04, finding 12).
    @Test func aGroupingQuoteTakesOnlyLabelsOfTheKindItArrangesBy() throws {
        let checked = try Self.validator().validate(Self.answer([
            "senders": .array([Self.asked("EDP Comercial", "by sender")]), "types": .array([Self.asked("invoice", "invoices")]),
            "topics": .array([]), "dates": .array([]), "group_by": Self.grouped(("sender", "invoices by sender")),
        ]), request: "invoices by sender")
        #expect(checked.plan.labels.values(.type) == ["invoice"] && checked.plan.grouping == [.sender],
                "the type the request asks for stands though the grouping's quote covers its word: \(checked.plan)")
        #expect(checked.plan.labels.values(.sender).isEmpty,
                "a sender only the arranging words ground is still none: \(checked.notes)")
    }

    /// A word inside the arrangement's quote that is not the whole quote may limit: "Lisbon" in a quote of the whole
    /// request "contracts mentioning Lisbon by sender" asks for contracts that mention Lisbon, and dropping it unseen
    /// returned every contract. It goes back to the model, named, and given again it is kept (second review of
    /// 2026-10-04, finding 1).
    @Test func aWordInsideTheArrangementsQuoteGoesBackToTheModelAndGivenAgainIsKept() throws {
        let request = "contracts mentioning Lisbon by sender"
        let answer = try Self.answer([
            "senders": .array([]), "dates": .array([]), "topics": .array([]), "types": .array([Self.asked("contract", "contracts")]),
            "words": Self.strings("Lisbon"), "group_by": Self.grouped(("sender", request)),
        ])
        let sentBack = SentBack()
        let sent2 = #expect(throws: GuessSentBack<ValidatedSearchPlan>.self, "the word is named back to the model, not dropped unseen") {
            try Self.validator().validate(answer, request: request, sentBack: sentBack)
        }
        sent2?.sent()
        #expect(sent2?.problems == [
            "words: “Lisbon” is among the words group_by quotes as asking to arrange the documents (“\(request)”): "
                + "give it as a word only when every document found must contain it",
        ])
        let again = try Self.validator().validate(answer, request: request, sentBack: sentBack)
        #expect(again.plan.words == ["Lisbon"] && again.plan.labels.values(.type) == ["contract"] && again.plan.grouping == [.sender],
                "given again after being told, the task asks for contracts that mention Lisbon, arranged by sender: \(again.plan)")
        #expect(again.notes.contains("words: “Lisbon” is among the words that arrange the documents (“\(request)”), and is kept as the model gives it as a word again"),
                "and the trace says so: \(again.notes)")
    }

    /// Alternatives a request lists are labels of one kind, of which a document needs one, while it must hold every word:
    /// those the model gives as words among the alternatives it gives as labels would be asked of every document together,
    /// and find none (QA 2026-10-04, TSK-4), so the answer goes back to the model naming them, rather than the words being
    /// dropped unseen (review of 2026-10-04, findings 2 and 11).
    @Test func wordsTheRequestListsAmongALabelsAlternativesGoBackToTheModel() throws {
        let request = "invoices and receipts about electricity water gas internet phone insurance taxes rent from Portugal mentioning meter"
        let sent3 = #expect(throws: GuessSentBack<ValidatedSearchPlan>.self, "the words carrying on the list of topics are alternatives, a word apart is not") {
            try Self.validator().validate(Self.answer([
                "senders": .array([]), "dates": .array([]),
                "topics": .array(["electricity", "water", "gas", "internet", "phone"].map { Self.asked($0, $0) }),
                "jurisdictions": .array([Self.asked("Portugal", "Portugal")]),
                "words": Self.strings("insurance", "taxes", "rent", "meter"), "group_by": .array([]),
            ]), request: request)
        }
        sent3?.sent()
        #expect(sent3?.problems == [
            "words: “insurance”, “taxes”, “rent” sit among the topics the request lists, of which a document needs only one, "
                + "while it must hold every word: give them as topics, not words",
        ])
        let sent4 = #expect(throws: GuessSentBack<ValidatedSearchPlan>.self, "a word written between two of a kind's alternatives is one more") {
            try Self.validator().validate(Self.answer([
                "senders": .array([]), "dates": .array([]), "types": .array([Self.asked("invoice", "bills")]),
                "topics": .array([Self.asked("electricity", "electricity"), Self.asked("water", "water"), Self.asked("rent", "rent")]),
                "words": Self.strings("insurance"), "group_by": .array([]),
            ]), request: "bills for electricity, water, insurance or rent")
        }
        sent4?.sent()
        #expect(sent4?.problems == [
            "words: “insurance” sit among the topics the request lists, of which a document needs only one, "
                + "while it must hold every word: give them as topics, not words",
        ])
        let single = try Self.validator().validate(Self.answer([
            "senders": .array([]), "dates": .array([]), "topics": .array([Self.asked("electricity", "electricity")]),
            "words": Self.strings("meter"), "group_by": .array([]),
        ]), request: "electricity meter readings")
        #expect(single.plan.words == ["meter"], "a word beside a kind's one label is no alternative: nothing is listed")
    }

    /// A word sent back as an alternative that the model gives as a word again is its answer to being told, and is kept,
    /// so a request is not failed for a word the model reads otherwise.
    @Test func anAlternativeTheModelGivesAsAWordAgainIsKept() throws {
        let answer = try Self.answer([
            "dates": .array([]), "types": .array([Self.asked("invoice", "faturas")]),
            "senders": .array([Self.asked("EDP Comercial", "EDP"), Self.asked("Galp Energia", "Galp")]),
            "words": Self.strings("multa"), "group_by": .array([]),
        ])
        let request = "faturas EDP Galp multa"
        let sentBack = SentBack()
        let first = #expect(throws: GuessSentBack<ValidatedSearchPlan>.self, "the first time, the word right after the senders goes back") {
            try Self.validator().validate(answer, request: request, sentBack: sentBack)
        }
        first?.sent()
        let again = try Self.validator().validate(answer, request: request, sentBack: sentBack)
        #expect(again.plan.words == ["multa"], "given again after being told, it is the model's word")
        #expect(again.notes.contains("words: “multa” sit among the senders the request lists, and are kept as the model gives them as words again"),
                "and the trace says so: \(again.notes)")
    }

    /// A word that only stands near a kind's alternatives, or near a word their quotes share with the rest of the request,
    /// is not one of them: the task asks for it (review of 2026-10-04, finding 2).
    @Test func aWordNearAKindsAlternativesButNotAmongThemStaysAWord() throws {
        for (request, senders, type, word) in [
            ("invoices from EDP or Galp with penalty", [("EDP Comercial", "EDP"), ("Galp Energia", "Galp")], "invoices", "penalty"),
            ("faturas da EDP e da Galp que falam da multa", [("EDP Comercial", "da EDP"), ("Galp Energia", "da Galp")], "faturas", "multa"),
            ("faturas da EDP e da Galp que falam da multa da luz", [("EDP Comercial", "da EDP"), ("Galp Energia", "da Galp")], "faturas", "multa"),
        ] {
            let checked = try Self.validator().validate(Self.answer([
                "senders": .array(senders.map { Self.asked($0.0, $0.1) }), "types": .array([Self.asked("invoice", type)]),
                "topics": .array([]), "dates": .array([]), "words": Self.strings(word), "group_by": .array([]),
            ]), request: request)
            #expect(checked.plan.words == [word] && checked.plan.labels.values(.sender) == ["EDP Comercial", "Galp Energia"],
                    "“\(word)” is asked of every document, beside one of the two senders: \(checked.notes)")
        }
    }

    /// A request written without spaces between its words (Chinese, Japanese, Thai) is read word by word as
    /// NaturalLanguage tells them apart, so a quote of some of its words grounds a label (AGENTS.md §4.5; review of
    /// 2026-10-04, finding 7).
    @Test func aRequestWrittenWithoutSpacesIsReadWordByWord() throws {
        let chinese = try Self.validator().validate(Self.answer([
            "senders": .array([Self.asked("国家电网", "发件人")]), "types": .array([Self.asked("invoice", "发票")]),
            "topics": .array([Self.asked("electricity", "电费"), Self.asked("water", "水费")]), "dates": .array([Self.asked("2025", "2025年")]),
            "words": Self.strings("电费"), "group_by": Self.grouped(("sender", "按发件人")),
        ]), request: "2025年的电费发票，按发件人")
        #expect(chinese.plan.labels == [DocumentLabel(kind: .type, value: "invoice"), DocumentLabel(kind: .date, value: "2025"),
                                        DocumentLabel(kind: .topic, value: "electricity")] && chinese.plan.grouping == [.sender],
                "the type, the year and the topic the request's words ask for, arranged by sender: \(chinese.notes)")
        #expect(chinese.notes.contains("topics: “water” is not asked for by the request (“水费”), dropped"),
                "a quote of words the request does not have still grounds nothing: \(chinese.notes)")
        let thai = try Self.validator().validate(Self.answer([
            "senders": .array([]), "types": .array([Self.asked("invoice", "ใบแจ้งหนี้")]),
            "topics": .array([Self.asked("electricity", "ค่าไฟฟ้า")]), "dates": .array([Self.asked("2025", "ปี 2025")]),
            "group_by": .array([]),
        ]), request: "ใบแจ้งหนี้ค่าไฟฟ้าปี 2025")
        #expect(thai.plan.labels.values(.type) == ["invoice"] && thai.plan.labels.values(.topic) == ["electricity"]
                    && thai.plan.labels.values(.date) == ["2025"], "each label a Thai request's words ask for: \(thai.notes)")
    }
}
