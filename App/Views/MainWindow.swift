import ArrumatorCore
import SwiftUI

/// The main window: a quiet sidebar of lists and folders, and one page at a time.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            page.frame(maxWidth: .infinity, maxHeight: .infinity).background(Style.page)
        }
        .overlay(alignment: .bottom) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
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
            case .learned: LearnedPage()
            case .logic: LogicPage()
            case let .folder(id): FolderPage(folderID: id).id(id)
            case .history: HistoryPage()
            case .statistics: StatisticsView()
            }
        }
    }
}

/// Lists at the top, the archive's areas and folders below, search above and a small menu at the foot, as in
/// Things. Counts appear only where something is waiting.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    /// The user's folders as a tree the sidebar can fold open, as deep as the archive goes.
    private var tree: [FolderNode] { model.taxonomy.map { FolderNode.tree(of: $0) } ?? [] }

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
            if !tree.isEmpty {
                Section("Archive") {
                    OutlineGroup(tree, children: \.children) { node in
                        Label(node.folder.name, systemImage: "folder").tag(Destination.folder(node.folder.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { search }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func count(_ destination: Destination) -> Int {
        switch destination {
        case .incoming: model.ingest.queued
        case .review: model.reviewCount
        case .learned: model.pendingProposals
        case .logic: model.rethink.status == .ready ? model.rethink.choices : 0
        default: 0
        }
    }

    private var search: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $model.searchText).textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let attention = model.attention {
                Text(attention).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { Task { await model.togglePause() } } label: {
                Image(systemName: model.settings?.paused == true ? "play.fill" : "pause.fill")
            }
            .help(model.settings?.paused == true ? "Resume filing" : "Pause filing")
            Menu {
                Button("Statistics") { model.go(.statistics) }
                Button("History") { model.go(.history) }
                Divider()
                Button("Open Incoming Folder") { if let path = model.settings?.incomingURL.path { model.open(path) } }
                Button("Open Archive Folder") { if let path = model.settings?.archiveURL.path { model.open(path) } }
                Button("Switch Archive…") {
                    if let chosen = FolderPicker.choose(title: "Choose the archive to file into", startingAt: model.settings?.archivePath) {
                        Task { await model.switchArchive(to: chosen) }
                    }
                }
                .disabled(model.switchingArchive)
                Divider()
                Button("Settings…") { model.show(.settings) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

/// A folder of the sidebar's tree and the folders inside it; nil for none, so it shows no disclosure triangle.
struct FolderNode: Identifiable, Hashable {
    let folder: TaxonomyFolder
    let children: [FolderNode]?
    var id: Int64 { folder.id }

    static func tree(of taxonomy: TaxonomySnapshot, inside code: String? = nil) -> [FolderNode] {
        let folders = code == nil ? taxonomy.topLevel : taxonomy.children(of: code).filter(\.holdsUserDocuments)
        return folders.map { folder in
            let inside = tree(of: taxonomy, inside: folder.code)
            return FolderNode(folder: folder, children: inside.isEmpty ? nil : inside)
        }
    }
}
