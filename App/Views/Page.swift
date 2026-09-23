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
        ScrollView {
            VStack(alignment: .leading, spacing: Style.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: Style.sectionTitleSize, weight: .semibold))
                Spacer()
                trailing().font(.callout)
            }
            Divider().padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 0) { content() }
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
    var busy = false
    /// Sentences wrap onto a second line; file names stay on one, shortened in the middle.
    var wraps = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                Group {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol).foregroundStyle(tint)
                    }
                }
                .frame(width: 18)
                Text(title).lineLimit(wraps ? 2 : 1).truncationMode(wraps ? .tail : .middle)
                    .fixedSize(horizontal: false, vertical: wraps)
                Spacer(minLength: 16)
                if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if let tag { Tag(tag) }
            }
            if let subtitle {
                Text(highlighted: subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 27)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, subtitle == nil && !wraps ? 0 : 5)
        .frame(minHeight: Style.rowHeight)
        .background(hovering ? Style.hover : .clear, in: .rect(cornerRadius: Style.rowCornerRadius))
        .contentShape(.rect)
        .onHover { hovering = $0 }
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
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.7), in: .capsule)
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
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.quaternary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            action().buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// A single quiet line about the state of the app, with an optional action.
struct Notice: View {
    let text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Palette.attention)
            Text(text).foregroundStyle(.secondary)
            if let action { Button(action.title, action: action.run).buttonStyle(.link) }
            Spacer()
        }
        .font(.callout)
    }
}
