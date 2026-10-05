import ArrumatorCore
import SwiftUI

/// The sidebar's labels, below the lists and the filter, as `SidebarLabelLayout` lays them out: a scroll view of rows of
/// its own, never a `List`. A sidebar list is an `NSTableView`, and narrowing the labels takes most of its rows out and
/// puts others in at once; AppKit then laid its rows out again from inside its own update (`endUpdates`, keeping the top
/// row in place, measured its row heights again from inside measuring them), which it warns is a reentrant table delegate
/// and will become an assert. Rows in a stack have no table to reenter.
///
/// It takes the keyboard as one stop, as a list does, so Tab reaches it whether keyboard navigation is on or off: the
/// arrow keys move a highlight through what is shown (`SidebarLabelLayout.stops`), Return or Space acts on it as a
/// click does, Left and Right fold and unfold a kind on its heading, and Escape goes back to Filter Labels. With keyboard
/// navigation on, Tab reaches each row, heading and button too (`rowAction`), which shows its own focus ring, and the
/// arrow keys then move that focus, never a highlight beside it. VoiceOver's cursor moves with the keyboard. Only the
/// labels scroll, never under the filter above or the bar below: a hairline under the filter shows while they are
/// scrolled.
struct SidebarLabelList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let layout: SidebarLabelLayout
    @Binding var folded: Set<LabelKind>
    @Binding var inFull: Set<SidebarLabelLayout.ListID>
    @Binding var filter: String
    /// What the arrow keys are on while the container has the keyboard. Moving onto a label chooses nothing, as choosing
    /// narrows the documents and lists other labels.
    @State private var keyed: SidebarLabelLayout.Stop?
    @State private var scrolled = false
    /// Whether the container has the keyboard, as one stop.
    @FocusState private var focused: Bool
    /// The row, heading or button that has focus of its own, as keyboard navigation brings focus to each with Tab.
    @FocusState private var rowFocused: SidebarLabelLayout.Stop?
    /// What VoiceOver is on, moved with the arrow keys.
    @AccessibilityFocusState private var spoken: SidebarLabelLayout.Stop?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(layout.lists) { list in
                        heading(list)
                        ForEach(list.labels, id: \.label) { usage in
                            let stop = SidebarLabelLayout.Stop.label(usage.label)
                            SidebarLabel(usage: usage, chosen: model.session.labelSelection.contains(usage.label),
                                         keyed: shows(stop)) {
                                keyed = stop
                                model.choose(usage.label)
                            }
                            .stop(stop, focus: $rowFocused, spoken: $spoken)
                        }
                        if let more = list.more {
                            button(more == .showMore ? Wording.showMore : Wording.showFewer, stop: .more(list.id))
                        }
                    }
                    if layout.nothingFound {
                        Text(Wording.noLabelsMatch(filter)).foregroundStyle(.secondary)
                            .padding(.horizontal, Style.sidebarLabelRowPadding)
                            .frame(minHeight: Style.rowHeight, alignment: .leading)
                    }
                    if layout.filtered {
                        button(Wording.clearFilter, stop: .clearFilter)
                    }
                }
                .padding(Style.sidebarLabelsInsets)
                // A row, heading or button Tab brings focus to shows it as any control does.
                .focusEffectDisabled(false)
            }
            // Named as one, its rows each with their own names within.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Wording.sidebarLabels)
            .focusable(!layout.stops.isEmpty, interactions: .edit)
            .focused($focused)
            // While the container itself has the keyboard, the highlight of the row the arrow keys are on shows where it
            // is, as a list's does; a ring round the whole sidebar would not. Only the container's own ring: what is in
            // it shows its own again above.
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space, .escape]) { press($0.key) }
            .onChange(of: focused) { _, focused in
                if focused, layout.current(focused: nil, highlighted: keyed) == nil { keyed = layout.stops.first }
            }
            .onChange(of: rowFocused) { _, row in
                // Back on the container, Shift-Tab finds the highlight where focus last was.
                if let row { keyed = row }
            }
            .onChange(of: keyed) { _, keyed in
                if let keyed { proxy.scrollTo(keyed) }
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0 } action: { _, now in
                scrolled = now
            }
            .overlay(alignment: .top) { if scrolled { Divider() } }
        }
    }

    /// Whether the highlight is on `stop`: only while the container itself has the keyboard, not a row of it, whose own
    /// focus ring shows where the keyboard is.
    private func shows(_ stop: SidebarLabelLayout.Stop) -> Bool { focused && rowFocused == nil && keyed == stop }

    @ViewBuilder private func heading(_ list: SidebarLabelLayout.LabelList) -> some View {
        if let kind = list.id {
            KindHeading(kind: kind, folded: list.folded, keyed: shows(.heading(kind))) {
                keyed = .heading(kind)
                act(on: .heading(kind))
            }
            .stop(.heading(kind), focus: $rowFocused, spoken: $spoken)
            .padding(.top, Style.sidebarLabelHeadingTopPadding)
        } else {
            Text(Wording.mostUsedLabels)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, Style.sidebarLabelRowPadding)
                .frame(minHeight: Style.rowHeight, alignment: .bottomLeading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Show More, Show Fewer or Clear Filter, quiet under the labels: a row like the labels', so Return and Space act on
    /// it as on them, whatever has the keyboard.
    private func button(_ title: String, stop: SidebarLabelLayout.Stop) -> some View {
        Text(title).foregroundStyle(.secondary)
            .padding(.horizontal, Style.sidebarLabelRowPadding)
            .frame(maxWidth: .infinity, minHeight: Style.rowHeight, alignment: .leading)
            .background(shows(stop) ? Style.sidebarLabelKeyed : .clear, in: .rect(cornerRadius: Style.rowCornerRadius))
            .contentShape(.rect)
            .rowAction {
                keyed = stop
                act(on: stop)
            }
            .stop(stop, focus: $rowFocused, spoken: $spoken)
    }

    private func press(_ key: KeyEquivalent) -> KeyPress.Result {
        let current = layout.current(focused: rowFocused, highlighted: keyed)
        if key == .downArrow || key == .upArrow {
            guard let next = key == .downArrow ? layout.stop(after: current) : layout.stop(before: current) else { return .ignored }
            move(to: next)
        } else if key == .return || key == .space {
            guard let current else { return .ignored }
            act(on: current)
        } else if key == .leftArrow || key == .rightArrow {
            guard let kind = layout.kind(on: current, unfolding: key == .rightArrow) else { return .ignored }
            act(on: .heading(kind))
        } else if key == .escape {
            // Filter Labels takes the cursor (`LabelFilter`), as a list's search field does.
            model.labelFilterWanted = true
        } else {
            return .ignored
        }
        return .handled
    }

    /// Moves the keyboard onto `stop`: the focus, when a row has it, else the highlight; and VoiceOver's cursor with it.
    private func move(to stop: SidebarLabelLayout.Stop) {
        keyed = stop
        if rowFocused != nil { rowFocused = stop }
        if voiceOver { spoken = stop }
    }

    /// What a click on `stop` does, and Return or Space on it.
    private func act(on stop: SidebarLabelLayout.Stop) {
        switch stop {
        case let .label(label): model.choose(label)
        case let .heading(kind): if folded.contains(kind) { folded.remove(kind) } else { folded.insert(kind) }
        case let .more(list): if inFull.contains(list) { inFull.remove(list) } else { inFull.insert(list) }
        case .clearFilter: filter = ""
        }
    }
}

/// A kind's heading in the sidebar, in its colour: clicking it, or Return or Space on it, folds its labels away, or
/// unfolds them, as the chevron shown under the pointer says. VoiceOver reads it as a heading and a button, collapsed
/// or expanded as a disclosure triangle is.
private struct KindHeading: View {
    @Environment(\.sidebarRowSize) private var rowSize
    let kind: LabelKind
    let folded: Bool
    let keyed: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Style.sidebarLabelSpacing) {
            Text(Wording.labelKinds(kind)).foregroundStyle(Palette.labelKind(kind)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: folded ? "chevron.right" : "chevron.down").foregroundStyle(.secondary)
                .opacity(hovering || keyed ? 1 : 0).accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, Style.sidebarLabelRowPadding)
        .frame(minHeight: Style.sidebarLabelRowHeight(rowSize))
        .background(keyed ? Style.sidebarLabelKeyed : .clear, in: .rect(cornerRadius: Style.rowCornerRadius))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .rowAction(toggle)
        .accessibilityLabel(Wording.labelKinds(kind))
        .accessibilityValue(Wording.labelKindFolded(folded))
        .accessibilityAddTraits(.isHeader)
        .help(Wording.foldLabelKind(kind, folded: folded))
    }
}

/// One label in the sidebar, in its kind's colour, with how many of the documents in view have it: choosing it narrows
/// the documents shown to those that have it, and choosing it again lets go of it. VoiceOver reads it as a button named
/// as the label, with its count as its value, selected while it is chosen.
private struct SidebarLabel: View {
    @Environment(\.sidebarRowSize) private var rowSize
    let usage: LabelUsage
    let chosen: Bool
    /// Whether the arrow keys are on it.
    let keyed: Bool
    let choose: () -> Void

    var body: some View {
        let label = usage.label
        HStack(spacing: Style.sidebarLabelSpacing) {
            Image(systemName: chosen ? "tag.fill" : "tag").foregroundStyle(Palette.labelKind(label.kind))
                .frame(width: Style.sidebarLabelSymbolWidth).accessibilityHidden(true)
            Text(Wording.label(label)).lineLimit(1).truncationMode(.middle).fontWeight(chosen ? .semibold : .regular)
            Spacer(minLength: Style.sidebarLabelSpacing)
            Text(usage.documents, format: .number).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(Style.sidebarLabelFont(rowSize))
        .padding(.horizontal, Style.sidebarLabelRowPadding)
        .frame(minHeight: Style.sidebarLabelRowHeight(rowSize))
        .background(keyed ? Style.sidebarLabelKeyed : .clear, in: .rect(cornerRadius: Style.rowCornerRadius))
        .contentShape(.rect)
        .rowAction(choose)
        .accessibilityLabel(Wording.label(label))
        .accessibilityValue(Text(usage.documents, format: .number))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .help(Wording.sidebarLabelHelp(label.kind, chosen: chosen))
    }
}

private extension View {
    /// Makes this row `stop`: what the arrow keys move focus and VoiceOver's cursor to, and scroll to.
    func stop(_ stop: SidebarLabelLayout.Stop, focus: FocusState<SidebarLabelLayout.Stop?>.Binding,
              spoken: AccessibilityFocusState<SidebarLabelLayout.Stop?>.Binding) -> some View {
        focused(focus, equals: stop).accessibilityFocused(spoken, equals: stop).id(stop)
    }
}
