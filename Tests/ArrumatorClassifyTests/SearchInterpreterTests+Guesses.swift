@testable import ArrumatorClassify
import ArrumatorCore
import Foundation
import Testing

/// What a plan holds that its request may not bear out, which goes back to the model once and stands when given again:
/// a title in another language than the request's, and a kind of document the person's question never names.
extension SearchInterpreterTests {
    /// The task is named in the request's language (QA 2026-10-04, TSK-3: an English request named in Portuguese): a
    /// title the detector is sure is in another goes back once, named, and stands when given again; one of names and
    /// numbers it cannot tell is not sent back.
    @Test func aTitleInAnotherLanguageThanTheRequestGoesBackOnce() throws {
        let request = "all the electricity invoices I received this year from my energy supplier, arranged by month"
        let fields: [String: JSONValue] = ["types": .array([Self.asked("invoice", "invoices")]), "topics": .array([Self.asked("electricity", "electricity")]),
                                           "senders": .array([]), "dates": .array([])]
        let sentBack = SentBack()
        let portuguese = try Self.answer(fields.merging(["title": .string("Faturas de eletricidade recebidas este ano")]) { $1 })
        let sent = #expect(throws: GuessSentBack<ValidatedSearchPlan>.self, "a Portuguese title of an English request goes back") {
            try Self.validator().validate(portuguese, request: request, sentBack: sentBack)
        }
        sent?.sent()
        #expect(sent?.problems == ["title: “Faturas de eletricidade recebidas este ano” is in Portuguese, while the request is in English; "
            + "name the task in English, the language of the request"])
        let again = try Self.validator().validate(portuguese, request: request, sentBack: sentBack)
        #expect(again.plan.title == "Faturas de eletricidade recebidas este ano"
                    && again.notes.contains { $0.hasSuffix(AnswerValidator.keptGivenAgain) }, "given again, it stands: \(again.notes)")
        let named = try Self.validator().validate(Self.answer(fields.merging(["title": .string("EDP 2026")]) { $1 }), request: request)
        #expect(named.plan.title == "EDP 2026" && named.notes.isEmpty, "a title the detector cannot place is not sent back")
    }

    /// A request the model makes for more documents names a kind only when the person's question does (QA 2026-10-04,
    /// CNV-4: "anything about the dentist" found as attestations or medical reports, missing the one dental ticket): a
    /// type the question does not write goes back, named, and is kept when given again; a task's own request, the
    /// person's words, is not checked so.
    @Test func aKindOfDocumentTheQuestionDoesNotNameGoesBackFromAFind() throws {
        let question = "do I have anything about the dentist?"
        let find = "dental attestations or medical reports"
        let typed = try Self.answer(["types": .array([Self.asked("attestation", "attestations"), Self.asked("medical-report", "medical reports")]),
                                     "topics": .array([Self.asked("dental care", "dental")]), "senders": .array([]), "dates": .array([]),
                                     "title": .string("Dental documents")])
        let sentBack = SentBack()
        let sent = #expect(throws: GuessSentBack<ValidatedSearchPlan>.self, "kinds the person never named go back") {
            try Self.validator().validate(typed, request: find, question: question, sentBack: sentBack)
        }
        sent?.sent()
        #expect(sent?.problems == [
            "types: “attestation” (“attestations”) is a kind of document the person's question does not name: give a kind only when they name it",
            "types: “medical-report” (“medical reports”) is a kind of document the person's question does not name: give a kind only when they name it",
        ], "each kind is named")
        let again = try Self.validator().validate(typed, request: find, question: question, sentBack: sentBack)
        #expect(again.plan.labels.values(.type) == ["attestation", "medical-report"] && again.notes.contains { $0.hasSuffix(AnswerValidator.keptGivenAgain) },
                "given again, it is the model's answer: \(again.notes)")
        let own = try Self.validator().validate(typed, request: find)
        #expect(own.plan.labels.values(.type) == ["attestation", "medical-report"] && own.notes.isEmpty, "a task's own request is the person's words, and is not checked so")
    }

    /// A kind the question names in another inflection, or an earlier question of the conversation names, is named: a
    /// plural, a case or a follow-up ("and those of 2023?") never sends it back.
    @Test func aKindTheQuestionNamesInflectedOrEarlierIsNamed() throws {
        let v = try Self.validator()
        #expect(v.inflected("invoice", "invoices") && v.inflected("fatura", "faturas") && v.inflected("квитанции", "квитанция"),
                "a plural or a case is the same word")
        #expect(!v.inflected("invoice", "insurance") && !v.inflected("receipt", "recibo"), "another word is not")
        let typed = try Self.answer(["types": .array([Self.asked("invoice", "invoices")]), "senders": .array([]), "topics": .array([]),
                                     "dates": .array([Self.asked("2023", "2023")]), "title": .string("Dentist invoices 2023")])
        let named = try v.validate(typed, request: "dentist invoices from 2023", question: "do I have the dentist's invoice?")
        #expect(named.plan.labels.values(.type) == ["invoice"] && named.notes.isEmpty, "the question's singular names the plural")
        let followUp = try v.validate(typed, request: "dentist invoices from 2023", question: "my dentist invoices, please\nand those of 2023?")
        #expect(followUp.notes.isEmpty, "an earlier question of the conversation names it too")
    }

    /// An exchange that already told the model of its title, whose title then stands, for a check of something else.
    static func toldOfItsTitle() -> SentBack {
        let told = SentBack()
        told.tell([SearchSchema.titleKey])
        return told
    }
}
