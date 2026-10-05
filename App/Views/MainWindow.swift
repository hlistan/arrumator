import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// The main window: a quiet sidebar of lists, and one page at a time.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if case let .failed(why) = model.phase {
                StartFailed(why: why)
            } else {
                NavigationSplitView {
                    Sidebar().navigationSplitViewColumnWidth(min: Style.sidebarMinWidth, ideal: Style.sidebarIdealWidth, max: Style.sidebarMaxWidth)
                } detail: {
                    VStack(spacing: 0) {
                        if model.settings?.onboardingCompleted == true, model.session.work == .away, let archive = model.archive {
                            ArchiveAway(path: archive.path)
                        }
                        page.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Style.page)
                }
            }
        }
        .showsLastError()
    }

    @ViewBuilder private var page: some View {
        switch model.session.destination {
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

/// Why the app could not start, in place of every page, and a way to try again: never the window that sets the app up,
/// which would take a failure for an app not set up yet.
private struct StartFailed: View {
    @Environment(AppModel.self) private var model
    let why: String

    var body: some View {
        VStack(spacing: Style.emptyStateSpacing) {
            Image(systemName: RuntimeActivity.Mark.problem.symbol).font(.system(size: Style.emptyStateSymbolSize))
                .foregroundStyle(Palette.problem).accessibilityHidden(true)
            Text(Wording.notStarted).font(.title2.weight(.semibold))
            Text(why).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            Button(Wording.tryAgain) { Task { await model.retryStart() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.phase == .starting)
        }
        .padding(Style.pageHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Style.page)
    }
}

/// Above every page while the archive's folder is not there, as on a disk not connected: what it is, the folder's path
/// on a line of its own, shortened in the middle, and a way to open it again once it is back, or to file into another.
///
/// It sits outside the page's scroll view, so the window lays out as tall as it is: its text is never fixed at the
/// height it asks for, which the split view measures at a width next to nothing, a line per character, thousands of
/// points for a long path. The window's content was then taller than the window, centred in it, the notice above the
/// window and the sidebar's foot below it. Its sentence takes at most `Style.archiveAwayMaxLines` lines, and the path
/// one.
private struct ArchiveAway: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        HStack(spacing: Style.noticeSpacing) {
            Image(systemName: RuntimeActivity.Mark.problem.symbol).foregroundStyle(Palette.attention).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Style.archiveAwayLineSpacing) {
                Text(Wording.archiveAwayNotice).foregroundStyle(.secondary).lineLimit(Style.archiveAwayMaxLines)
                Text(path).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
            }
            Spacer(minLength: 0)
            Button(Wording.tryAgain) { model.tryOpeningAgain() }
            Button(Wording.chooseAnotherArchive) {
                if let chosen = FolderPicker.choose(title: Wording.chooseArchive, startingAt: path) {
                    Task { await model.switchArchive(to: chosen) }
                }
            }
            .disabled(model.switchingArchive)
        }
        .font(.callout)
        .padding(Style.archiveAwayInsets)
        .background(.quaternary.opacity(Style.filterFieldFillOpacity))
    }
}

/// Lists, then the labels, and a bar at the foot, as in Things. The archive has no folders to list: documents are found
/// by their labels, listed below the lists with how many documents have each, the most used first, in one list or kind
/// by kind (`AppSettings.groupLabelsByKind`), each kind in its own colour. Choosing one shows the documents that have it,
/// and leaves only the labels those documents have, to narrow them down further. A filter between the lists and the
/// labels lists only the labels written with its text in them, and a button below them clears it. Besides the labels',
/// counts appear only where something is waiting; Tasks has a spinner instead while a search request is being read.
///
/// Only the labels scroll. The lists and the filter stay at the top (`SidebarLists`, `LabelFilter`) and the bar at the
/// foot (`SidebarBar`), and the labels scroll in a container of their own between them (`SidebarLabelList`).
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// The labels of the documents in view, kind by kind, the most used first: every document's when none is chosen.
    @State private var usage: [LabelKind: [LabelUsage]] = [:]
    /// Text in the filter field: only the labels written with it in them are listed, each one of them.
    @State private var filter = ""
    /// Kinds folded away, while the labels are grouped by kind.
    @State private var folded: Set<LabelKind> = []
    /// Lists of labels listed in full, past `interface.sidebarLabelsPerKind` or `interface.sidebarLabels`, until Show
    /// Fewer.
    @State private var inFull: Set<SidebarLabelLayout.ListID> = []

    var body: some View {
        VStack(spacing: 0) {
            SidebarLists()
            // Outside the lists, as a field in a row of a list is outside the window's key view loop: Tab reaches it.
            if !usage.isEmpty || !filter.isEmpty { LabelFilter(filter: $filter) }
            // Until the runtime is there, there are no labels, nor limits to list them by; the bar stays at the foot.
            if let limits = model.runtime?.config.interface {
                SidebarLabelList(layout: layout(limits), folded: $folded, inFull: $inFull, filter: $filter)
            } else {
                Spacer(minLength: 0)
            }
            SidebarBar()
        }
        .task(id: "\(model.session.labelSelection)|\(model.activity)") { await loadLabels() }
    }

    /// The labels as the sidebar lists them.
    private func layout(_ limits: InterfaceConfig) -> SidebarLabelLayout {
        SidebarLabelLayout(usage: usage, filter: filter, chosen: model.session.labelSelection,
                           arrangement: .init(groupedByKind: model.settings?.groupLabelsByKind == true, folded: folded, inFull: inFull),
                           limits: limits)
    }

    private func loadLabels() async {
        let selection = model.session.labelSelection
        guard let loaded = await model.load(Wording.loadLabelsAction, { try await $0.services.labels.usage(within: selection) }) else { return }
        usage = loaded
        // With no labels, no filter is shown to take Filter Labels: the command is let go of, not left to put the cursor
        // there whenever labels come.
        if loaded.isEmpty, filter.isEmpty { model.labelFilterWanted = false }
    }
}

/// The lists: a sidebar list of their own that never scrolls, so they stay in sight however far the labels are scrolled,
/// and whose rows look and line up as the labels' do.
///
/// A list has no height of its own, and a sidebar row is as tall as the sidebar icon size chosen in System Settings makes
/// it, so this one is as tall as its rows measure: down to where its last row ends (`ListsEnd`), measured again when the
/// rows change size. Until then it is as tall as it estimates its rows at, and at least
/// `Style.sidebarListsEstimatedHeight`, so that every row is laid out, to be measured, and none is cut off.
private struct SidebarLists: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarRowSize) private var rowSize
    /// Where the list begins in the window.
    @State private var top: CGFloat?
    /// Where its last row ends in the window, and for which rows.
    @State private var end: ListsEnd?
    /// How tall the list estimates its rows at, those not laid out yet included.
    @State private var estimatedHeight: CGFloat = 0

    var body: some View {
        List(selection: Binding(get: { model.session.destination }, set: { if let d = $0 { model.go(d) } })) {
            Section {
                ForEach(Destination.lists, id: \.self) { destination in
                    HStack(spacing: Style.sidebarSpinnerSpacing) {
                        Label {
                            Text(destination.title)
                        } icon: {
                            Image(systemName: destination.symbol).foregroundStyle(destination.tint)
                        }
                        // Not a count: that a search request is being read, or a question answered, is seen from any page.
                        if destination == .tasks, let work = model.tasksAtWork {
                            Spacer(minLength: 0)
                            ProgressView().controlSize(.mini).help(work)
                        }
                    }
                    .badge(count(destination))
                    .tag(destination)
                    .listRowBackground(endMarker(last: destination == Destination.lists.last))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        // Each measure is kept once the list has laid out: its height changed while AppKit lays out its rows is a
        // reentrant table delegate, which AppKit warns will become an assert.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            Task { @MainActor in if estimatedHeight != height { estimatedHeight = height } }
        }
        .frame(height: height)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { minY in
            Task { @MainActor in if top != minY { top = minY } }
        }
    }

    /// Down to where the last row ends, once it is measured for the rows in view; until then what the list estimates.
    private var height: CGFloat {
        guard let top, let end, end.rowSize == rowSize else {
            return max(Style.sidebarListsEstimatedHeight, estimatedHeight)
        }
        return max(0, end.maxY - top)
    }

    /// A row's background, clear as the sidebar is, that measures where the row ends when it is the last one. A row's
    /// background fills the whole row, as its highlight does when it is chosen, while its content sits inset within it.
    /// The rows of a list on macOS are laid out apart from it, where its coordinate space does not reach, so the row and
    /// the list are both measured in the window's.
    private func endMarker(last: Bool) -> some View {
        let rowSize = rowSize
        return Color.clear.onGeometryChange(for: ListsEnd?.self) { geometry in
            last ? ListsEnd(rowSize: rowSize, maxY: geometry.frame(in: .global).maxY) : nil
        } action: { measured in
            guard let measured else { return }
            Task { @MainActor in if end != measured { end = measured } }
        }
    }

    private func count(_ destination: Destination) -> Int {
        switch destination {
        case .incoming: model.session.ingest.queued
        case .review: model.session.reviewCount
        case .labels: model.session.labelSuggestionCount
        default: 0
        }
    }
}

/// Where the last row of the sidebar's lists ends in the window, measured with rows of `rowSize`: rows of another size
/// end elsewhere, and are measured again.
nonisolated private struct ListsEnd: Equatable {
    let rowSize: SidebarRowSize
    let maxY: CGFloat
}

/// Filter Labels, between the lists and the labels while there are labels to filter: a field of its own, in no list, so
/// Tab reaches it between them, as it does every text field (docs/review/swift-apple.md, X2 and X9); Edit › Filter
/// Labels (Option-Command-F) puts the cursor there too (`AppModel.filterLabels()`).
private struct LabelFilter: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: String
    @FocusState private var filtering: Bool

    var body: some View {
        HStack(spacing: Style.filterFieldSpacing) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(Wording.filterLabels, text: $filter).textFieldStyle(.plain)
                .accessibilityLabel(Wording.filterLabels)
                .focused($filtering)
                // Escape clears what was typed, then leaves the field, as a search field does.
                .onExitCommand { if filter.isEmpty { filtering = false } else { filter = "" } }
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").accessibilityLabel(Wording.clearFilter) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help(Wording.clearFilter)
            }
        }
        .padding(Style.filterFieldInsets)
        .background(.quaternary.opacity(Style.filterFieldFillOpacity), in: .rect(cornerRadius: Style.filterFieldCornerRadius))
        .padding(Style.filterFieldOuterInsets)
        // Also when the command opened the window, before this field was there to hear it.
        .task(id: model.labelFilterWanted) {
            guard model.labelFilterWanted else { return }
            filtering = true
            model.labelFilterWanted = false
        }
    }
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
        .accessibilityLabel(model.settings?.paused == true ? Wording.resumeFiling : Wording.pauseFiling)
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
            Button(Wording.openArchiveFolder) { if let path = model.archive?.path { model.open(path) } }
            Button(Wording.switchArchive) {
                if let chosen = FolderPicker.choose(title: Wording.chooseArchive, startingAt: model.archive?.path) {
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
        .accessibilityLabel(Wording.moreActions).help(Wording.moreActions)
    }

    private func loadProfiles() async {
        guard let runtime = model.runtime else { return }
        profiles = await runtime.profiles.list()
    }
}
