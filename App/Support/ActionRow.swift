import SwiftUI

/// A row of buttons that wraps: placed left to right, each whole, and onto the next row when the next does not fit, so no
/// title wraps or breaks within a word at the smallest window, and none is lost off its edge. The buttons from the one
/// marked `startsTrailingGroup()` on stand at the right edge of the row they land on, as a spacer would have put them.
///
/// It asks no geometry back: the size and the places are a pure function of the width it is offered, so a page that holds
/// one never lays itself out in a loop (AGENTS.md §4.7).
struct ActionRow: Layout {
    /// Between buttons of a row.
    var spacing: CGFloat
    /// Between rows.
    var rowSpacing: CGFloat

    /// Whether a button starts the group kept at the right edge of its row.
    fileprivate struct TrailingGroup: LayoutValueKey {
        static let defaultValue = false
    }

    /// The rows the buttons fall into at `width`: each button's index and size, in order.
    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].isEmpty ? size.width : used + spacing + size.width
            if needed > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                used = size.width
            } else {
                used = needed
            }
            rows[rows.count - 1].append((index, size))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let heights = rows.map { $0.map(\.size.height).max() ?? 0 }
        let widest = rows.map { row in row.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width == nil ? widest : min(widest, width),
                      height: heights.reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let height = row.map(\.size.height).max() ?? 0
            let trailing = row.firstIndex { subviews[$0.index][TrailingGroup.self] }
            var x = bounds.minX
            for (place, item) in row.enumerated() {
                if place == trailing {
                    let rest = row[place...].map(\.size.width).reduce(0, +) + spacing * CGFloat(row.count - place - 1)
                    x = max(x, bounds.maxX - rest)
                }
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + rowSpacing
        }
    }
}

extension View {
    /// Marks a button of an `ActionRow` as the first of the group kept at the right edge of its row (when `starts`, so a
    /// button can say it of its place without the view changing from one to another).
    func startsTrailingGroup(_ starts: Bool = true) -> some View { layoutValue(key: ActionRow.TrailingGroup.self, value: starts) }
}
