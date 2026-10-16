@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// How labels are shown to the person, by the card and by History alike (the QA run of 15 October 2026, C10-1, C3-4).
@Suite struct LabelDisplayTests {
    @Test func everyKindHasADistinctNameAndGroupName() {
        let names = LabelKind.allCases.map(\.name)
        let groups = LabelKind.allCases.map(\.groupName)
        #expect(names.allSatisfy { !$0.isEmpty } && Set(names).count == names.count, "one name per kind, none shared: \(names)")
        #expect(groups.allSatisfy { !$0.isEmpty } && Set(groups).count == groups.count, "and one for a group: \(groups)")
        #expect(zip(names, groups).allSatisfy { $0 != $1 }, "the group is not the single name")
        #expect(LabelKind.sender.name == "Sender" && LabelKind.party.name == "Person or Organisation" && LabelKind.object.name == "Thing",
                "the app's names for the kinds the command line calls sender=, party= and object=")
        #expect(LabelKind.party.groupName == "People and Organisations" && LabelKind.object.groupName == "Things", "and for their groups")
        #expect(LabelKind.party.sentenceName == "person or organisation" && LabelKind.sender.sentenceName == "sender", "a sentence names a kind in lower case")
    }

    @Test func aReadingSummaryShowsLabelsAsTheCardDoes() {
        let summary = PipelineServices.readingSummary([
            DocumentLabel(kind: .type, value: "tax-assessment"),
            DocumentLabel(kind: .language, value: "ja"),
            DocumentLabel(kind: .period, value: "2026-07-04/2026-08-03"),
        ], problems: [], locale: TestTime.locale)
        #expect(summary == "Tax Assessment · Japanese · 4 Jul 2026 – 3 Aug 2026",
                "History shows a type, a language and a period as the card does, never as the model wrote them: \(summary)")
    }

    @Test func aValueThatCannotBeReadIsShownAsWritten() {
        let period = DocumentLabel(kind: .period, value: "2026-13")
        let language = DocumentLabel(kind: .language, value: "zz")
        let date = DocumentLabel(kind: .date, value: "someday")
        #expect(period.shown(locale: TestTime.locale) == "2026-13" && language.shown(locale: TestTime.locale) == "zz"
                    && date.shown(locale: TestTime.locale) == "someday", "a value that is no period, language or date is left as the model wrote it")
    }

    @Test func aLabelIsShownInTheLocaleItIsGiven() {
        let language = DocumentLabel(kind: .language, value: "ja")
        #expect(language.shown(locale: Locale(identifier: "pt_PT")) == "japonês", "the language is named in the locale given, never the Mac's")
        #expect(DocumentLabel(kind: .sender, value: "EDP Comercial").shown(locale: TestTime.locale) == "EDP Comercial", "a sender is as written")
    }

    @Test func nothingWorthALabelAndNothingReadStayAsTheyWere() {
        #expect(PipelineServices.readingSummary([], problems: [], locale: TestTime.locale) == "Nothing worth a label", "nothing found")
        #expect(PipelineServices.readingSummary([], problems: [DocumentAnalysis.Problem.corrupted], locale: TestTime.locale)
                    == "Nothing could be read of it; waits for you: the file is damaged", "nothing could be read of a damaged file")
    }
}
