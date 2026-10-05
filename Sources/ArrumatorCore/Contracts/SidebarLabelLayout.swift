import Foundation

/// The labels the app's sidebar lists, as it lays them out: in one list under Most Used, or kind by kind, each kind
/// folding away; each list the most used first, up to a limit until it is listed in full, with Show More or Show Fewer
/// after it; the labels chosen first, as every document in view has them, so they stay in sight however many other
/// labels are as used; and, while the filter has text, every label it finds and a way to clear it.
///
/// What the arrow keys move through (`stops`) is what is shown, in the order it is shown, so the keyboard reaches all of
/// it, a folded kind's heading included, with the labels listed in one container that takes focus as one stop.
public struct SidebarLabelLayout: Sendable, Equatable {
    /// A list of labels: a kind's, when they are grouped by kind, or the one list of the most used (`nil`).
    public typealias ListID = LabelKind?

    /// What follows a list cut at its limit: a way to list the rest, or, once they are, to go back.
    public enum More: Sendable, Equatable {
        case showMore
        case showFewer
    }

    /// One list, under its heading.
    public struct LabelList: Sendable, Equatable, Identifiable {
        public let id: ListID
        /// Folded away: only its heading is shown. Only a kind folds.
        public let folded: Bool
        /// The labels shown, the chosen first: none while folded.
        public let labels: [LabelUsage]
        /// What follows them, while the list is longer than its limit and not folded.
        public let more: More?
    }

    /// What the arrow keys move through, and Return or Space acts on.
    public enum Stop: Sendable, Hashable {
        /// A kind's heading: folds the kind away, or unfolds it.
        case heading(LabelKind)
        /// A label: chooses it, or lets go of it.
        case label(DocumentLabel)
        /// A list's Show More or Show Fewer.
        case more(ListID)
        /// Clear Filter, below the labels while the filter has text.
        case clearFilter
    }

    /// How the labels are listed, as the user left them.
    public struct Arrangement: Sendable, Equatable {
        /// Kind by kind (`AppSettings.groupLabelsByKind`), else in one list.
        public var groupedByKind: Bool
        /// Kinds folded away.
        public var folded: Set<LabelKind>
        /// Lists listed in full, past their limit, until Show Fewer.
        public var inFull: Set<ListID>

        public init(groupedByKind: Bool, folded: Set<LabelKind> = [], inFull: Set<ListID> = []) {
            self.groupedByKind = groupedByKind
            self.folded = folded
            self.inFull = inFull
        }
    }

    public let lists: [LabelList]
    /// Whether the filter has text: every label it found is listed, and Clear Filter after them.
    public let filtered: Bool
    /// What the arrow keys move through, in the order shown.
    public let stops: [Stop]

    /// - Parameters:
    ///   - usage: the labels of the documents in view, kind by kind, each kind's most used first
    ///     (`LabelStore.usage(within:)`).
    ///   - filter: the text of Filter Labels: only the labels written with it in them are listed, each of them.
    ///   - chosen: the labels chosen, which come first in their list.
    ///   - limits: how many labels a list shows before Show More (`InterfaceConfig.sidebarLabels`,
    ///     `sidebarLabelsPerKind`).
    public init(usage: [LabelKind: [LabelUsage]], filter: String, chosen: [DocumentLabel], arrangement: Arrangement,
                limits: InterfaceConfig) {
        filtered = !filter.isEmpty
        let found = usage.matching(filter)
        let wanted: [(id: ListID, labels: [LabelUsage], limit: Int)] = arrangement.groupedByKind
            ? LabelKind.allCases.compactMap { kind in
                found[kind].flatMap { $0.isEmpty ? nil : (id: kind, labels: $0, limit: limits.sidebarLabelsPerKind) }
            }
            : (found.isEmpty ? [] : [(id: nil, labels: found.ranked(), limit: limits.sidebarLabels)])
        let filtered = filtered
        lists = wanted.map { wanted in
            let folded = wanted.id.map(arrangement.folded.contains) ?? false
            let inFull = arrangement.inFull.contains(wanted.id)
            let ordered = wanted.labels.filter { chosen.contains($0.label) } + wanted.labels.filter { !chosen.contains($0.label) }
            let cut = !filtered && wanted.labels.count > wanted.limit
            return LabelList(id: wanted.id, folded: folded,
                             labels: folded ? [] : (cut && !inFull ? Array(ordered.prefix(wanted.limit)) : ordered),
                             more: folded || !cut ? nil : (inFull ? .showFewer : .showMore))
        }
        stops = lists.flatMap { list in
            (list.id.map { [Stop.heading($0)] } ?? []) + list.labels.map { .label($0.label) } + (list.more == nil ? [] : [.more(list.id)])
        } + (filtered ? [.clearFilter] : [])
    }

    /// Whether the filter has text that no label is written with.
    public var nothingFound: Bool { filtered && lists.isEmpty }

    /// The stop the keyboard is on, which the arrow keys move from and Return, Space, Left and Right act on: the one
    /// that has focus of its own, as keyboard navigation brings focus to each with Tab, else the one highlighted while
    /// the labels' container has focus, whichever is still shown. Nil when neither is.
    public func current(focused: Stop?, highlighted: Stop?) -> Stop? {
        [focused, highlighted].lazy.compactMap { $0 }.first(where: stops.contains)
    }

    /// The kind whose heading `stop` is, when Left (`unfolding` false) would fold it or Right (`unfolding` true) unfold
    /// it: nil on anything else, and on a kind already folded or unfolded so.
    public func kind(on stop: Stop?, unfolding: Bool) -> LabelKind? {
        guard case let .heading(kind)? = stop, let list = lists.first(where: { $0.id == kind }), list.folded == unfolding else {
            return nil
        }
        return kind
    }

    /// The stop after `stop`, as the down arrow moves: the first when `stop` is nil or no longer shown, and the last
    /// stays the last. Nil only when nothing is shown.
    public func stop(after stop: Stop?) -> Stop? {
        guard let stop, let index = stops.firstIndex(of: stop) else { return stops.first }
        return stops[min(index + 1, stops.count - 1)]
    }

    /// The stop before `stop`, as the up arrow moves: the last when `stop` is nil or no longer shown, and the first
    /// stays the first. Nil only when nothing is shown.
    public func stop(before stop: Stop?) -> Stop? {
        guard let stop, let index = stops.firstIndex(of: stop) else { return stops.last }
        return stops[max(index - 1, 0)]
    }
}
