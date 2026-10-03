import ArrumatorCore
import SwiftUI

/// A page as Things lays one out: the list's symbol and a large title, a line of notes, then sections, all at a
/// readable width in the middle of the window.
struct Page<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    /// Shown faintly after the title, such as a folder's code.
    var accessory: String?
    var notes: String?
    @ViewBuilder let content: () -> Content

    init(_ destination: Destination, notes: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: destination.title, symbol: destination.symbol, tint: destination.tint, notes: notes, content: content)
    }

    init(title: String, symbol: String, tint: Color, accessory: String? = nil, notes: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.accessory = accessory
        self.notes = notes
        self.content = content
    }

    var body: some View {
        // Lazy, so a long list builds the rows in sight, not every row it has.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Style.sectionSpacing) {
                VStack(alignment: .leading, spacing: Style.pageTitleSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: Style.titleSymbolSpacing) {
                        Image(systemName: symbol)
                            .font(.system(size: Style.titleSymbolSize, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(title).font(.system(size: Style.titleSize, weight: .bold))
                        if let accessory {
                            Text(accessory).font(.system(size: Style.titleSize, weight: .regular)).foregroundStyle(.tertiary)
                        }
                    }
                    if let notes, !notes.isEmpty {
                        Text(notes).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                content()
            }
            .frame(maxWidth: Style.pageMaxWidth, alignment: .leading)
            .padding(.horizontal, Style.pageHorizontalPadding)
            .padding(.vertical, Style.pageVerticalPadding)
            .frame(maxWidth: .infinity)
        }
        .background(Style.page)
    }
}

/// A section: a small bold heading over a hairline, then its rows.
struct PageSection<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.content = content
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.sectionHeadingSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: Style.sectionTitleSize, weight: .semibold))
                Spacer()
                trailing().font(.callout)
            }
            Divider().padding(.bottom, Style.sectionRuleGap)
            LazyVStack(alignment: .leading, spacing: 0) { content() }
        }
    }
}

/// One line of a list: a status mark, a name, and a quiet detail at the end. Highlights under the pointer.
struct ListRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    var tag: String?
    var subtitle: String?
    /// The kind of label the subtitle lists, when it lists labels of one kind: shown after a tag in that kind's colour,
    /// with the kind named in its help, as the sidebar shows a label.
    var subtitleKind: LabelKind?
    var busy = false
    /// Sentences wrap onto a second line; file names stay on one, shortened in the middle.
    var wraps = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Style.rowSubtitleSpacing) {
            HStack(spacing: Style.rowSymbolSpacing) {
                Group {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        // The row's detail says the same in words; the symbol's own name ("Selected") would mislead.
                        Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                    }
                }
                .frame(width: Style.rowSymbolWidth)
                Text(title).lineLimit(wraps ? Style.rowTitleMaxLines : 1).truncationMode(wraps ? .tail : .middle)
                    .fixedSize(horizontal: false, vertical: wraps)
                Spacer(minLength: Style.rowDetailMinGap)
                if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if let tag { Tag(tag) }
            }
            if let subtitle, let subtitleKind {
                Label {
                    Text(subtitle).lineLimit(Style.rowSubtitleMaxLines)
                } icon: {
                    Image(systemName: "tag").foregroundStyle(Palette.labelKind(subtitleKind))
                }
                .font(.callout).foregroundStyle(.secondary).padding(.leading, Style.rowSubtitleIndent)
                .help(Wording.labelKinds(subtitleKind))
            } else if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(Style.rowSubtitleMaxLines).padding(.leading, Style.rowSubtitleIndent)
            }
        }
        .padding(.horizontal, Style.rowHorizontalPadding)
        .padding(.vertical, subtitle == nil && !wraps ? 0 : Style.rowVerticalPadding)
        .frame(minHeight: Style.rowHeight)
        .background(hovering ? Style.hover : .clear, in: .rect(cornerRadius: Style.rowCornerRadius))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// How many clicks choose a row and open a document, as everywhere on the Mac.
private enum Clicks {
    static let choose = 1
    static let open = 2
}

extension View {
    /// What choosing a row does: a click, Return or Space once the keyboard has brought focus to it, or VoiceOver's
    /// default action. Rows are views, not controls, and reach the keyboard only so.
    func rowAction(_ action: @escaping () -> Void) -> some View {
        rowAction(clicks: Clicks.choose, action)
    }

    /// What opens a document in the app that shows it: a double click, as in the Finder, Return or Space once the
    /// keyboard has brought focus to it, or VoiceOver's default action.
    func openAction(_ action: @escaping () -> Void) -> some View {
        rowAction(clicks: Clicks.open, action)
    }

    private func rowAction(clicks: Int, _ action: @escaping () -> Void) -> some View {
        onTapGesture(count: clicks, perform: action)
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.return, .space]) { _ in
                action()
                return .handled
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

/// A switch VoiceOver names by its title: in a grouped form, macOS shows the title as a text of its own beside it.
struct NamedToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn).accessibilityLabel(title)
    }
}

/// A small grey capsule, like a Things tag.
struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(Style.tagInsets)
            .background(.quaternary.opacity(Style.tagFillOpacity), in: .capsule)
    }
}

/// What an empty page says: a faint symbol, one sentence, and at most one way forward.
struct EmptyState<Action: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder let action: () -> Action

    init(symbol: String, text: String, @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.symbol = symbol
        self.text = text
        self.action = action
    }

    var body: some View {
        VStack(spacing: Style.emptyStateSpacing) {
            Image(systemName: symbol).font(.system(size: Style.emptyStateSymbolSize)).foregroundStyle(.quaternary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            action().buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Style.emptyStatePadding)
    }
}

/// A single quiet line about the state of the app, with an optional action.
struct Notice: View {
    let text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: Style.noticeSpacing) {
            Image(systemName: "info.circle").foregroundStyle(Palette.attention)
            Text(text).foregroundStyle(.secondary)
            if let action { Button(action.title, action: action.run).buttonStyle(.link) }
            Spacer()
        }
        .font(.callout)
    }
}

/// Why the last action failed, at the foot of a window until it is clicked away: every window the user acts in shows it,
/// so a refusal is never lost in a window that is not in front.
private struct LastError: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(Style.errorBannerInsets)
                    .background(.regularMaterial, in: .capsule)
                    .padding()
                    .rowAction { model.lastError = nil }
            }
        }
    }
}

extension View {
    /// Shows why the last action failed at the foot of the window (`AppModel.lastError`).
    func showsLastError() -> some View { modifier(LastError()) }
}
