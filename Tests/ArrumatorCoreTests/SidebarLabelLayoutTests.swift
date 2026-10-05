import ArrumatorCore
import Foundation
import Testing

/// The sidebar's labels as the app lays them out (`SidebarLabelLayout`): in one list or kind by kind, cut at a limit
/// until listed in full, the chosen first, a kind folding away, every label a filter finds; and what the arrow keys move
/// through, which is what is shown, in the order shown, as the labels are listed in a container of the app's own.
@Suite struct SidebarLabelLayoutTests {
    static func label(_ kind: LabelKind, _ value: String) -> DocumentLabel { DocumentLabel(kind: kind, value: value) }
    static func usage(_ kind: LabelKind, _ value: String, _ documents: Int) -> LabelUsage {
        LabelUsage(label: label(kind, value), documents: documents)
    }

    /// Three senders, two types and one topic, each kind's most used first, as `LabelStore.usage(within:)` gives them.
    static let offered: [LabelKind: [LabelUsage]] = [
        .sender: [usage(.sender, "EDP", 5), usage(.sender, "MEO", 3), usage(.sender, "Autoridade Tributária", 1)],
        .type: [usage(.type, "invoice", 6), usage(.type, "contract", 2)],
        .topic: [usage(.topic, "electricity", 4)],
    ]

    /// Two labels a list, so the senders and the one list are cut.
    static func limits() throws -> InterfaceConfig {
        var limits = try PipelineConfig.bundledDefaults().interface
        limits.sidebarLabelsPerKind = 2
        limits.sidebarLabels = 2
        return limits
    }

    static func layout(filter: String = "", chosen: [DocumentLabel] = [], grouped: Bool, folded: Set<LabelKind> = [],
                       inFull: Set<SidebarLabelLayout.ListID> = [], usage: [LabelKind: [LabelUsage]] = offered) throws -> SidebarLabelLayout {
        SidebarLabelLayout(usage: usage, filter: filter, chosen: chosen,
                           arrangement: .init(groupedByKind: grouped, folded: folded, inFull: inFull), limits: try limits())
    }

    static func values(_ list: SidebarLabelLayout.LabelList) -> [String] { list.labels.map(\.label.value) }

    // MARK: Laid out

    @Test func inOneListTheMostUsedComeFirstCutAtTheLimitWithShowMore() throws {
        let layout = try Self.layout(grouped: false)
        #expect(layout.lists.map(\.id) == [nil], "one list, under Most Used")
        #expect(Self.values(layout.lists[0]) == ["invoice", "EDP"], "the two most used, whatever their kind")
        #expect(layout.lists[0].more == .showMore, "the rest are a click away")
        let full = try Self.layout(grouped: false, inFull: [nil])
        #expect(full.lists[0].labels.count == 6 && full.lists[0].more == .showFewer, "listed in full, with a way back")
    }

    @Test func kindByKindEachKindIsCutOnItsOwnAndOnlyKindsWithLabelsAreListed() throws {
        let layout = try Self.layout(grouped: true, inFull: [.type])
        #expect(layout.lists.map(\.id) == [.sender, .type, .topic], "kinds in their order, none without a label")
        #expect(Self.values(layout.lists[0]) == ["EDP", "MEO"] && layout.lists[0].more == .showMore, "the senders are cut at two")
        #expect(layout.lists[1].more == nil, "a kind no longer than its limit has nothing to show more of, listed in full or not")
        #expect(layout.lists[2].more == nil, "nor has one with a single label")
    }

    @Test func theChosenComeFirstEvenPastTheLimit() throws {
        let chosen = Self.label(.sender, "Autoridade Tributária")
        let layout = try Self.layout(chosen: [chosen], grouped: true)
        #expect(Self.values(layout.lists[0]) == ["Autoridade Tributária", "EDP"],
                "a chosen label stays in sight though fewer documents have it, and the rest keep their order")
        let one = try Self.layout(chosen: [chosen], grouped: false)
        #expect(Self.values(one.lists[0]) == ["Autoridade Tributária", "invoice"], "in one list too")
    }

    @Test func aFoldedKindShowsOnlyItsHeading() throws {
        let layout = try Self.layout(grouped: true, folded: [.sender])
        #expect(layout.lists[0].folded && layout.lists[0].labels.isEmpty && layout.lists[0].more == nil,
                "folded away: no labels, no Show More")
        #expect(!layout.lists[1].folded && Self.values(layout.lists[1]) == ["invoice", "contract"], "the other kinds are as they were")
        let one = try Self.layout(grouped: false, folded: [.sender])
        #expect(one.lists[0].labels.count == 2, "the one list never folds, whatever kinds were folded when grouped")
    }

    @Test func aFilterListsEveryLabelItFindsAndClearFilter() throws {
        let layout = try Self.layout(filter: "e", grouped: true)
        #expect(Self.values(layout.lists[0]) == ["EDP", "MEO", "Autoridade Tributária"] && layout.lists[0].more == nil,
                "every sender found, past the limit, with nothing more to show")
        #expect(layout.filtered && !layout.nothingFound, "what was found, and the filter can be cleared")
        #expect(layout.stops.last == .clearFilter, "Clear Filter comes last, after the labels")
        let none = try Self.layout(filter: "zzz", grouped: true)
        #expect(none.lists.isEmpty && none.nothingFound && none.stops == [.clearFilter], "nothing found says so, and can still be cleared")
    }

    @Test func noLabelsListsNothingAndHasNoStops() throws {
        let layout = try Self.layout(grouped: true, usage: [:])
        #expect(layout.lists.isEmpty && layout.stops.isEmpty && !layout.nothingFound, "an archive without labels lists nothing")
        #expect(layout.stop(after: nil) == nil && layout.stop(before: nil) == nil, "and the arrow keys have nothing to move to")
    }

    // MARK: The keyboard

    @Test func theStopsAreWhatIsShownInTheOrderShown() throws {
        let layout = try Self.layout(grouped: true, folded: [.type])
        #expect(layout.stops == [.heading(.sender), .label(Self.label(.sender, "EDP")), .label(Self.label(.sender, "MEO")), .more(.sender),
                                 .heading(.type), .heading(.topic), .label(Self.label(.topic, "electricity"))],
                "headings fold, so they are stops; a folded kind's labels are not")
        let one = try Self.layout(grouped: false)
        #expect(one.stops == [.label(Self.label(.type, "invoice")), .label(Self.label(.sender, "EDP")), .more(nil)],
                "Most Used heads the one list but does nothing, so it is no stop")
    }

    @Test func theArrowsMoveOneStopAndStopAtTheEnds() throws {
        let layout = try Self.layout(grouped: false)
        let invoice = SidebarLabelLayout.Stop.label(Self.label(.type, "invoice"))
        #expect(layout.stop(after: nil) == invoice, "down from nothing highlighted, the first")
        #expect(layout.stop(before: nil) == .more(nil), "up from nothing highlighted, the last")
        #expect(layout.stop(after: invoice) == .label(Self.label(.sender, "EDP")), "down, the next")
        #expect(layout.stop(after: .more(nil)) == .more(nil), "the last stays the last")
        #expect(layout.stop(before: invoice) == invoice, "the first stays the first")
        let gone = SidebarLabelLayout.Stop.label(Self.label(.topic, "taxes"))
        #expect(layout.stop(after: gone) == invoice && layout.stop(before: gone) == .more(nil),
                "a label no longer shown, as after narrowing, starts again from an end")
    }

    @Test func theKeyboardIsOnWhatHasFocusElseWhatIsHighlighted() throws {
        let layout = try Self.layout(grouped: true)
        let edp = SidebarLabelLayout.Stop.label(Self.label(.sender, "EDP"))
        let invoice = SidebarLabelLayout.Stop.label(Self.label(.type, "invoice"))
        #expect(layout.current(focused: edp, highlighted: invoice) == edp,
                "a row Tab brought focus to is where the keyboard is, so the arrows move the focus it shows")
        #expect(layout.current(focused: nil, highlighted: invoice) == invoice, "else the highlight, while the container has focus")
        let gone = SidebarLabelLayout.Stop.label(Self.label(.topic, "taxes"))
        #expect(layout.current(focused: gone, highlighted: invoice) == invoice, "a row no longer shown is no longer where it is")
        #expect(layout.current(focused: nil, highlighted: gone) == nil, "nor is a highlight on one")
    }

    @Test func leftFoldsAKindOnItsHeadingAndRightUnfoldsIt() throws {
        let layout = try Self.layout(grouped: true, folded: [.type])
        #expect(layout.kind(on: .heading(.sender), unfolding: false) == .sender, "Left folds an unfolded kind")
        #expect(layout.kind(on: .heading(.sender), unfolding: true) == nil, "Right leaves it unfolded")
        #expect(layout.kind(on: .heading(.type), unfolding: true) == .type, "Right unfolds a folded kind")
        #expect(layout.kind(on: .heading(.type), unfolding: false) == nil, "Left leaves it folded")
        #expect(layout.kind(on: .label(Self.label(.sender, "EDP")), unfolding: false) == nil, "a label folds nothing")
        #expect(layout.kind(on: .heading(.party), unfolding: false) == nil, "nor does a kind not listed")
    }
}
