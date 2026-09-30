import ArrumatorCore
import SwiftUI

/// The main window: a quiet sidebar of lists, and one page at a time.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: Style.sidebarMinWidth, ideal: Style.sidebarIdealWidth, max: Style.sidebarMaxWidth)
        } detail: {
            page.frame(maxWidth: .infinity, maxHeight: .infinity).background(Style.page)
        }
        .overlay(alignment: .bottom) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(Style.errorBannerInsets)
                    .background(.regularMaterial, in: .capsule)
                    .padding()
                    .onTapGesture { model.lastError = nil }
            }
        }
    }

    @ViewBuilder private var page: some View {
        if !model.searchText.isEmpty {
            SearchPage()
        } else {
            switch model.destination {
            case .incoming: IncomingPage()
            case .review: ReviewPage()
            case .processed: ProcessedPage()
            case .labels: LabelsPage()
            case .labelled: LabelledPage()
            case .history: HistoryPage()
            case .statistics: StatisticsView()
            }
        }
    }
}

/// Lists, search above and a small menu at the foot, as in Things. The archive has no folders to list: documents are
/// found by their labels, listed below the lists kind by kind. Choosing one shows the documents that have it, and
/// leaves only the labels those documents have, to narrow them down further. Counts appear only where something is
/// waiting.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// The labels of the documents in view, kind by kind, the most used first: every document's when none is chosen.
    @State private var usage: [LabelKind: [LabelUsage]] = [:]
    @State private var collapsed: Set<LabelKind> = []
    /// Kinds whose labels are all listed, past `interface.sidebarLabelsPerKind`.
    @State private var listedInFull: Set<LabelKind> = []

    var body: some View {
        List(selection: Binding(get: { model.destination }, set: { if let d = $0 { model.go(d) } })) {
            Section {
                ForEach(Destination.lists, id: \.self) { destination in
                    Label {
                        Text(destination.title)
                    } icon: {
                        Image(systemName: destination.symbol).foregroundStyle(destination.tint)
                    }
                    .badge(count(destination))
                    .tag(destination)
                }
            }
            ForEach(LabelKind.allCases.filter { usage[$0]?.isEmpty == false }, id: \.self) { kind in
                Section(isExpanded: expanded(kind)) {
                    labels(kind)
                } header: {
                    Text(Wording.labelKinds(kind))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { search }
        .safeAreaInset(edge: .bottom) { footer }
        .task(id: "\(model.labelSelection)|\(model.activity)") { await loadLabels() }
    }

    private func expanded(_ kind: LabelKind) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(kind) }, set: { if $0 { collapsed.remove(kind) } else { collapsed.insert(kind) } })
    }

    /// A kind's labels, those chosen first, then the most used, up to `interface.sidebarLabelsPerKind` until the user
    /// asks for the rest.
    @ViewBuilder private func labels(_ kind: LabelKind) -> some View {
        let all = usage[kind] ?? []
        let ordered = all.filter { model.labelSelection.contains($0.label) } + all.filter { !model.labelSelection.contains($0.label) }
        let limit = listedInFull.contains(kind) ? ordered.count : (model.runtime?.config.interface.sidebarLabelsPerKind ?? ordered.count)
        ForEach(ordered.prefix(limit), id: \.label) { item in
            SidebarLabel(label: item.label, chosen: model.labelSelection.contains(item.label))
        }
        if ordered.count > limit {
            Button(Wording.showMore) { listedInFull.insert(kind) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private func loadLabels() async {
        let selection = model.labelSelection
        guard let loaded = await model.load(Wording.loadLabelsAction, { try await $0.services.labels.usage(within: selection) }) else { return }
        usage = loaded
    }

    private func count(_ destination: Destination) -> Int {
        switch destination {
        case .incoming: model.ingest.queued
        case .review: model.reviewCount
        case .labels: model.labelSuggestionCount
        default: 0
        }
    }

    private var search: some View {
        @Bindable var model = model
        return HStack(spacing: Style.searchFieldSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(Wording.search, text: $model.searchText).textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(Style.searchFieldInsets)
        .background(.quaternary.opacity(Style.searchFieldFillOpacity), in: .rect(cornerRadius: Style.searchFieldCornerRadius))
        .padding(Style.searchFieldMargins)
    }

    private var footer: some View {
        HStack(spacing: Style.sidebarFooterSpacing) {
            if let attention = model.attention {
                Text(attention).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                let paused = model.settings?.paused == true
                Task { await model.setPaused(!paused) }
            } label: {
                Image(systemName: model.settings?.paused == true ? "play.fill" : "pause.fill")
            }
            .help(model.settings?.paused == true ? Wording.resumeFiling : Wording.pauseFiling)
            Menu {
                Button(Destination.statistics.title) { model.go(.statistics) }
                Button(Destination.history.title) { model.go(.history) }
                Divider()
                Button(Wording.openIncomingFolder) { if let path = model.settings?.incomingURL.path { model.open(path) } }
                Button(Wording.openArchiveFolder) { if let path = model.settings?.archiveURL.path { model.open(path) } }
                Button(Wording.switchArchive) {
                    if let chosen = FolderPicker.choose(title: Wording.chooseArchive, startingAt: model.settings?.archivePath) {
                        Task { await model.switchArchive(to: chosen) }
                    }
                }
                .disabled(model.switchingArchive)
                Divider()
                Button(Wording.settings) { model.show(.settings) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(Style.sidebarFooterInsets)
    }
}

/// One label in the sidebar: choosing it narrows the documents shown to those that have it, and choosing it again lets
/// go of it.
private struct SidebarLabel: View {
    @Environment(AppModel.self) private var model
    let label: DocumentLabel
    let chosen: Bool

    var body: some View {
        Button { model.choose(label) } label: {
            Label {
                Text(Wording.label(label)).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: chosen ? "tag.fill" : "tag").foregroundStyle(chosen ? Destination.labelled.tint : .secondary)
            }
            .fontWeight(chosen ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(chosen ? Wording.showWithoutLabel : Wording.showOnlyWithLabel)
    }
}
