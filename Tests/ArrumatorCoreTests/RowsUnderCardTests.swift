import ArrumatorCore
import Testing

/// How a list reloads under an open card: Processed's rule, and search's, which closes the card of a row no longer found.
@Suite struct RowsUnderCardTests {
    struct Row: Equatable {
        var id: Int64
        var text: String
    }

    static func rows(_ pairs: [(Int64, String)]) -> [Row] { pairs.map { Row(id: $0.0, text: $0.1) } }

    /// The rows as `number:text`, so a test says each row's text as well as its place.
    static func shown(_ rows: [Row]) -> [String] { rows.map { "\($0.id):\($0.text)" } }

    @Test func mergedKeepsPlacesUpdatesEachRowDropsOnlyWhatIsGoneAndHoldsBackNewRows() {
        let shown = Self.rows([(3, "c"), (2, "b"), (1, "a")])
        let read = Self.rows([(4, "new"), (3, "c2"), (1, "a2")])
        #expect(Self.shown(RowsUnderCard.merged(shown: shown, read: read, gone: [2], id: \.id)) == ["3:c2", "1:a2"],
                "each row keeps its place and is as read now; the one gone leaves; the new one waits")
        #expect(Self.shown(RowsUnderCard.merged(shown: shown, read: read, gone: [], id: \.id)) == ["3:c2", "2:b", "1:a2"],
                "a row read leaves out that is not gone stays as it was")
        #expect(RowsUnderCard.merged(shown: [], read: read, gone: [], id: \.id).isEmpty, "with nothing shown there is nothing to keep in place")
    }

    @Test func rereadClosesTheCardOfARowNoLongerFound() {
        let shown = Self.rows([(3, "c"), (2, "b")])
        let read = Self.rows([(4, "new"), (3, "c2")])
        let result = RowsUnderCard.reread(shown: shown, read: read, open: 2, sameQuery: true, id: \.id)
        #expect(Self.shown(result.rows) == ["4:new", "3:c2"] && !result.keepsCard, "the open row is gone: its card closes and the rows are the ones read")
    }

    @Test func rereadKeepsPlacesWhileTheOpenRowIsFoundDropsWhatNoLongerMatchesAndHoldsBackNewRows() {
        let shown = Self.rows([(3, "c"), (2, "b"), (1, "a")])
        let read = Self.rows([(4, "new"), (3, "c2"), (1, "a2")])
        let result = RowsUnderCard.reread(shown: shown, read: read, open: 3, sameQuery: true, id: \.id)
        #expect(Self.shown(result.rows) == ["3:c2", "1:a2"] && result.keepsCard,
                "the open row stays, each is as read now, the one that no longer matches goes, and the new one waits")
    }

    @Test func rereadWithNoCardOpenGivesTheRowsRead() {
        let shown = Self.rows([(2, "b")])
        let read = Self.rows([(4, "new"), (2, "b2")])
        let result = RowsUnderCard.reread(shown: shown, read: read, open: nil, sameQuery: true, id: \.id)
        #expect(Self.shown(result.rows) == ["4:new", "2:b2"] && result.keepsCard, "nothing is held in place")
        let first = RowsUnderCard.reread(shown: [], read: read, open: 2, sameQuery: true, id: \.id)
        #expect(Self.shown(first.rows) == ["4:new", "2:b2"] && first.keepsCard, "and nothing shown yet is replaced")
    }

    /// A card open while the query changes: the rows are the new query's at once, new matches among them, and the card
    /// stays only if its document is still found. AC 14: what is typed is not held back behind a card.
    @Test func rereadOfAChangedQueryShowsItsRowsAtOnceAndKeepsTheCardOnlyOfAFoundRow() {
        let shown = Self.rows([(3, "c"), (2, "b"), (1, "a")])
        let read = Self.rows([(4, "new"), (1, "a2"), (3, "c2")])
        let found = RowsUnderCard.reread(shown: shown, read: read, open: 3, sameQuery: false, id: \.id)
        #expect(Self.shown(found.rows) == ["4:new", "1:a2", "3:c2"] && found.keepsCard && found.focus == nil,
                "the rows are the new query's, in its order, the new match among them, and the card of a row still found stays")
        let gone = RowsUnderCard.reread(shown: shown, read: read, open: 2, sameQuery: false, id: \.id)
        #expect(Self.shown(gone.rows) == ["4:new", "1:a2", "3:c2"] && !gone.keepsCard, "a card of a row the new query does not find closes")
        let none = RowsUnderCard.reread(shown: shown, read: read, open: nil, sameQuery: false, id: \.id)
        #expect(Self.shown(none.rows) == ["4:new", "1:a2", "3:c2"] && none.keepsCard && none.focus == nil, "with no card open they are just the rows read")
    }

    /// A card that closes because its row is no longer found leaves the keyboard on the row that takes its place: the one
    /// after it, else the one before it, else the first, never nowhere.
    @Test func whenTheCardClosesTheKeyboardGoesToTheNextRowElseThePreviousElseTheFirst() {
        let shown = Self.rows([(5, "e"), (4, "d"), (3, "c"), (2, "b"), (1, "a")])
        func focus(read: [(Int64, String)], open: Int64, sameQuery: Bool = true) -> Int64? {
            RowsUnderCard.reread(shown: shown, read: Self.rows(read), open: open, sameQuery: sameQuery, id: \.id).focus
        }
        #expect(focus(read: [(5, "e"), (4, "d"), (2, "b"), (1, "a")], open: 3) == 2, "the row after the closed one")
        #expect(focus(read: [(5, "e"), (4, "d"), (3, "c"), (2, "b")], open: 1) == 2, "no row after it: the one before")
        #expect(focus(read: [(5, "e"), (4, "d"), (1, "a")], open: 3) == 1, "the next that is still found, not the next that is gone")
        #expect(focus(read: [(9, "x"), (8, "y")], open: 3) == 9, "none of its neighbours found: the first row")
        #expect(focus(read: [(9, "x"), (8, "y")], open: 3, sameQuery: false) == 9, "as when the query changed")
        #expect(focus(read: [], open: 3) == nil, "and none when nothing is found")
        #expect(RowsUnderCard.reread(shown: shown, read: Self.rows([(3, "c")]), open: 3, sameQuery: true, id: \.id).focus == nil,
                "a card that stays asks for no focus")
    }
}
