import Foundation

/// How a list reloads under a card that is open: the rows keep their places so the card does not move from under the
/// reader. App presentation logic kept here, where `swift test` reaches it, so every page that lists documents shares one
/// rule (AGENTS.md §4.6).
public enum RowsUnderCard {
    /// The rows of `shown` keep their places, each as `read` gives it now. A row `read` leaves out goes only when `gone`
    /// holds its number, as when it left the index; otherwise it stays as it was. Rows new to `read` wait until the card
    /// closes.
    public static func merged<Row>(shown: [Row], read: [Row], gone: Set<Int64>, id: (Row) -> Int64?) -> [Row] {
        let byID = Dictionary(read.compactMap { row in id(row).map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        return shown.compactMap { row in
            guard let number = id(row) else { return row }
            return byID[number] ?? (gone.contains(number) ? nil : row)
        }
    }

    /// What a list that is searched again shows under the card of `open`, and where the keyboard goes when the card
    /// closes. With no card open, the rows are the ones read. When the open row is no longer found, its card closes
    /// (`keepsCard` is false), the rows are the ones read, and `focus` is the row that takes its place: the one after it,
    /// else the one before it, among those still found, else the first. When it is found, the card stays; for the same
    /// query the rows keep their places, as `merged` has them, and every row `read` leaves out is gone, for it no longer
    /// matches; for another query (`sameQuery` is false) the rows are the ones read at once, new matches among them, as
    /// there is no place to keep.
    public static func reread<Row>(shown: [Row], read: [Row], open: Int64?, sameQuery: Bool,
                                   id: (Row) -> Int64?) -> (rows: [Row], keepsCard: Bool, focus: Int64?) {
        guard let open else { return (read, true, nil) }
        let found = Set(read.compactMap(id))
        guard found.contains(open) else { return (read, false, replacement(for: open, shown: shown, among: found, rows: read, id: id)) }
        guard sameQuery, !shown.isEmpty else { return (read, true, nil) }
        let gone = Set(shown.compactMap(id)).subtracting(found)
        return (merged(shown: shown, read: read, gone: gone, id: id), true, nil)
    }

    private static func replacement<Row>(for open: Int64, shown: [Row], among found: Set<Int64>, rows: [Row], id: (Row) -> Int64?) -> Int64? {
        let order = shown.compactMap(id)
        if let at = order.firstIndex(of: open) {
            if let next = order[(at + 1)...].first(where: found.contains) { return next }
            if let previous = order[..<at].last(where: found.contains) { return previous }
        }
        return rows.compactMap(id).first
    }
}
