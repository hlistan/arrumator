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
        .showsLastError()
    }

    @ViewBuilder private var page: some View {
        switch model.destination {
        case .incoming: IncomingPage()
        case .review: ReviewPage()
        case .processed: ProcessedPage()
        case .labels: LabelsPage()
        case .tasks: TasksPage()
        case .labelled: LabelledPage()
        case .history: HistoryPage()
        case .statistics: StatisticsView()
        }
    }
}

/// Lists, then the labels, and a bar at the foot, as in Things. The archive has no folders to list: documents are found
/// by their labels, listed below the lists with how many documents have each, the most used first, in one list or kind
/// by kind (`AppSettings.groupLabelsByKind`), each kind in its own colour. Choosing one shows the documents that have it,
/// and leaves only the labels those documents have, to narrow them down further. A filter between the lists and the
/// labels lists only the labels written with its text in them, and a button below them clears it. Besides the labels',
/// counts appear only where something is waiting; Tasks has a spinner instead while a search request is being read.
///
/// Only the labels scroll. The lists and the filter stay at the top (`SidebarLists`) and the bar at the foot
/// (`SidebarBar`), and the labels scroll in a sidebar list of their own between them, never under either: a hairline
/// under the filter shows while they are scrolled.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// The labels of the documents in view, kind by kind, the most used first: every document's when none is chosen.
    @State private var usage: [LabelKind: [LabelUsage]] = [:]
    /// Text in the filter field: only the labels written with it in them are listed, each one of them.
    @State private var filter = ""
    @State private var collapsed: Set<LabelKind> = []
    /// Kinds whose labels are all listed, past `interface.sidebarLabelsPerKind`.
    @State private var listedInFull: Set<LabelKind> = []
    /// Whether the one list of labels is listed in full, past `interface.sidebarLabels`.
    @State private var rankedInFull = false
    /// Whether the labels are scrolled, so some are hidden under the filter.
    @State private var labelsScrolled = false

    var body: some View {
        let shown = usage.matching(filter)
        VStack(spacing: 0) {
            SidebarLists(filter: $filter, showsFilter: !usage.isEmpty || !filter.isEmpty)
            List { labelSections(shown) }
                .listStyle(.sidebar)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0 } action: { labelsScrolled = $1 }
                .overlay(alignment: .top) { if labelsScrolled { Divider() } }
            SidebarBar()
        }
        .task(id: "\(model.labelSelection)|\(model.activity)") { await loadLabels() }
    }

    /// The labels, in one list or kind by kind, and, while the filter has text, what it found and the button that
    /// clears it.
    @ViewBuilder private func labelSections(_ shown: [LabelKind: [LabelUsage]]) -> some View {
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
        if !filter.isEmpty {
            Section {
                if shown.isEmpty {
                    Text(Wording.noLabelsMatch(filter)).foregroundStyle(.secondary)
                }
                Button(Wording.clearFilter) { filter = "" }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    private func expanded(_ kind: LabelKind) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(kind) }, set: { if $0 { collapsed.remove(kind) } else { collapsed.insert(kind) } })
    }

    /// Labels in the order given, the most used first, up to `limit` until the user asks for the rest. A filter lists
    /// every label it finds. Those chosen come first, which keeps that order, as every document in view has them: they
    /// stay in sight however many other labels are as used.
    @ViewBuilder private func labels(_ listed: [LabelUsage], limit: Int?, showAll: @escaping () -> Void) -> some View {
        let chosen = listed.filter { model.labelSelection.contains($0.label) }
        let ordered = chosen + listed.filter { !model.labelSelection.contains($0.label) }
        let shown = filter.isEmpty ? Array(ordered.prefix(limit ?? ordered.count)) : ordered
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
}

/// The lists, and under them the label filter while there are labels to filter: a sidebar list of their own that never
/// scrolls, so they stay in sight however far the labels are scrolled, and whose rows look and line up as the labels' do.
///
/// A list has no height of its own, and a sidebar row is as tall as the sidebar icon size chosen in System Settings makes
/// it, so this one is as tall as its rows measure: down to where its last row ends (`ListsEnd`), measured again when the
/// rows change size or the filter comes or goes. Until then it is as tall as it estimates its rows at, and at least
/// `Style.sidebarListsEstimatedHeight`, so that every row is laid out, to be measured, and none is cut off.
private struct SidebarLists: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarRowSize) private var rowSize
    @Binding var filter: String
    let showsFilter: Bool
    /// Where the list begins in the window.
    @State private var top: CGFloat?
    /// Where its last row ends in the window, and for which rows.
    @State private var end: ListsEnd?
    /// How tall the list estimates its rows at, those not laid out yet included.
    @State private var estimatedHeight: CGFloat = 0

    var body: some View {
        List(selection: Binding(get: { model.destination }, set: { if let d = $0 { model.go(d) } })) {
            Section {
                ForEach(Destination.lists, id: \.self) { destination in
                    HStack(spacing: Style.sidebarSpinnerSpacing) {
                        Label {
                            Text(destination.title)
                        } icon: {
                            Image(systemName: destination.symbol).foregroundStyle(destination.tint)
                        }
                        // Not a count: that a search request is being read is seen from any page.
                        if destination == .tasks, let reading = model.taskQueue.reading {
                            Spacer(minLength: 0)
                            ProgressView().controlSize(.mini).help(Wording.readingRequest(with: reading.model))
                        }
                    }
                    .badge(count(destination))
                    .tag(destination)
                    .listRowBackground(endMarker(last: !showsFilter && destination == Destination.lists.last))
                }
            }
            if showsFilter {
                Section { filterField.listRowBackground(endMarker(last: true)) }
            }
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { estimatedHeight = $1 }
        .frame(height: height)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top = $0 }
    }

    /// Down to where the last row ends, once it is measured for the rows in view; until then what the list estimates.
    private var height: CGFloat {
        guard let top, let end, end.rowSize == rowSize, end.withFilter == showsFilter else {
            return max(Style.sidebarListsEstimatedHeight, estimatedHeight)
        }
        return max(0, end.maxY - top)
    }

    /// A row's background, clear as the sidebar is, that measures where the row ends when it is the last one. A row's
    /// background fills the whole row, as its highlight does when it is chosen, while its content sits inset within it.
    /// The rows of a list on macOS are laid out apart from it, where its coordinate space does not reach, so the row and
    /// the list are both measured in the window's.
    private func endMarker(last: Bool) -> some View {
        let (rowSize, withFilter) = (rowSize, showsFilter)
        return Color.clear.onGeometryChange(for: ListsEnd?.self) { geometry in
            last ? ListsEnd(rowSize: rowSize, withFilter: withFilter, maxY: geometry.frame(in: .global).maxY) : nil
        } action: { measured in
            if let measured { end = measured }
        }
    }

    private func count(_ destination: Destination) -> Int {
        switch destination {
        case .incoming: model.ingest.queued
        case .review: model.reviewCount
        case .labels: model.labelSuggestionCount
        default: 0
        }
    }

    private var filterField: some View {
        HStack(spacing: Style.filterFieldSpacing) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            TextField(Wording.filterLabels, text: $filter).textFieldStyle(.plain)
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(Style.filterFieldInsets)
        .background(.quaternary.opacity(Style.filterFieldFillOpacity), in: .rect(cornerRadius: Style.filterFieldCornerRadius))
    }
}

/// Where the last row of the sidebar's lists ends in the window, measured with rows of `rowSize`, with the filter under
/// them or without: rows of another size, or the filter coming or going, end elsewhere, and are measured again.
nonisolated private struct ListsEnd: Equatable {
    let rowSize: SidebarRowSize
    let withFilter: Bool
    let maxY: CGFloat
}

/// The bar at the sidebar's foot, which never scrolls: the model profile in use, to choose another as Settings › Models
/// does, then pause or resume, and a menu of the rest. Why the app is not filing, while it is not, is a line above them,
/// where it cannot push them aside.
private struct SidebarBar: View {
    @Environment(AppModel.self) private var model
    /// Every profile, as `ModelProfileActions.list()` orders them.
    @State private var profiles: [ModelProfileListing] = []

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: Style.sidebarBarLineSpacing) {
                if let attention = model.attention {
                    Text(attention).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(attention)
                }
                HStack(spacing: Style.sidebarBarSpacing) {
                    if let settings = model.settings, !profiles.isEmpty {
                        ProfileInUsePicker(inUse: settings.profile, profiles: profiles)
                            .pickerStyle(.menu).labelsHidden()
                            .help(Wording.profileInUseHelp)
                    }
                    Spacer(minLength: 0)
                    pauseButton
                    menu
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(Style.sidebarBarInsets)
        }
        // Read again whenever the settings change, as they do when a profile is added, renamed or removed in Settings.
        .task(id: model.settings) { await loadProfiles() }
    }

    private var pauseButton: some View {
        Button {
            let paused = model.settings?.paused == true
            Task { await model.setPaused(!paused) }
        } label: {
            Image(systemName: model.settings?.paused == true ? "play.fill" : "pause.fill")
        }
        .help(model.settings?.paused == true ? Wording.resumeFiling : Wording.pauseFiling)
    }

    private var menu: some View {
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

    private func loadProfiles() async {
        guard let runtime = model.runtime else { return }
        profiles = await runtime.profiles.list()
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
