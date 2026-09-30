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

/// Lists, a search for labels above and a small menu at the foot, as in Things. The archive has no folders to list:
/// documents are found by their labels, listed below the lists with how many documents have each, the most used first,
/// in one list or kind by kind (`AppSettings.groupLabelsByKind`), each kind in its own colour. Choosing one shows the
/// documents that have it, and leaves only the labels those documents have, to narrow them down further. The search
/// lists only the labels written with its text in them. Besides the labels', counts appear only where something is
/// waiting.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// The labels of the documents in view, kind by kind, the most used first: every document's when none is chosen.
    @State private var usage: [LabelKind: [LabelUsage]] = [:]
    /// Text in the search field: only the labels written with it in them are listed, each one of them.
    @State private var search = ""
    @State private var collapsed: Set<LabelKind> = []
    /// Kinds whose labels are all listed, past `interface.sidebarLabelsPerKind`.
    @State private var listedInFull: Set<LabelKind> = []
    /// Whether the one list of labels is listed in full, past `interface.sidebarLabels`.
    @State private var rankedInFull = false

    var body: some View {
        let shown = usage.matching(search)
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
            if model.settings?.groupLabelsByKind == true {
                ForEach(LabelKind.allCases.filter { shown[$0] != nil }, id: \.self) { kind in
                    Section(isExpanded: expanded(kind)) {
                        labels(shown[kind] ?? [], limit: listedInFull.contains(kind) ? nil : model.runtime?.config.interface.sidebarLabelsPerKind) {
                            listedInFull.insert(kind)
                        }
                    } header: {
                        Text(Wording.labelKinds(kind)).foregroundStyle(Palette.labelKind(kind))
                    }
                }
            } else if !shown.isEmpty {
                Section(Wording.mostUsedLabels) {
                    labels(shown.ranked(), limit: rankedInFull ? nil : model.runtime?.config.interface.sidebarLabels) { rankedInFull = true }
                }
            }
            if shown.isEmpty, !search.isEmpty {
                Text(Wording.noLabelsMatch(search)).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { searchField }
        .safeAreaInset(edge: .bottom) { footer }
        .task(id: "\(model.labelSelection)|\(model.activity)") { await loadLabels() }
    }

    private func expanded(_ kind: LabelKind) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(kind) }, set: { if $0 { collapsed.remove(kind) } else { collapsed.insert(kind) } })
    }

    /// Labels in the order given, the most used first, up to `limit` until the user asks for the rest. A search lists
    /// every label it finds. Those chosen come first, which keeps that order, as every document in view has them: they
    /// stay in sight however many other labels are as used.
    @ViewBuilder private func labels(_ listed: [LabelUsage], limit: Int?, showAll: @escaping () -> Void) -> some View {
        let chosen = listed.filter { model.labelSelection.contains($0.label) }
        let ordered = chosen + listed.filter { !model.labelSelection.contains($0.label) }
        let shown = search.isEmpty ? Array(ordered.prefix(limit ?? ordered.count)) : ordered
        ForEach(shown, id: \.label) { item in
            SidebarLabel(usage: item, chosen: model.labelSelection.contains(item.label))
        }
        if shown.count < listed.count {
            Button(Wording.showMore, action: showAll)
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

    private var searchField: some View {
        HStack(spacing: Style.searchFieldSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(Wording.searchLabels, text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
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
                Toggle(Wording.groupLabelsByKind, isOn: Binding(get: { model.settings?.groupLabelsByKind == true },
                                                                set: { grouped in Task { await model.update { $0.groupLabelsByKind = grouped } } }))
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

/// One label in the sidebar, in its kind's colour, with how many of the documents in view have it: choosing it narrows
/// the documents shown to those that have it, and choosing it again lets go of it.
private struct SidebarLabel: View {
    @Environment(AppModel.self) private var model
    let usage: LabelUsage
    let chosen: Bool

    var body: some View {
        let label = usage.label
        Button { model.choose(label) } label: {
            Label {
                Text(Wording.label(label)).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: chosen ? "tag.fill" : "tag").foregroundStyle(Palette.labelKind(label.kind))
            }
            .fontWeight(chosen ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .badge(usage.documents)
        .help(Wording.sidebarLabelHelp(label.kind, chosen: chosen))
    }
}
