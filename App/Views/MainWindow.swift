import ArrumatorCore
import SwiftUI

/// The main window: a quiet sidebar of lists, and one page at a time.
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
            case .history: HistoryPage()
            case .statistics: StatisticsView()
            }
        }
    }
}

/// Lists, search above and a small menu at the foot, as in Things. The archive has no folders to list: documents are
/// found by their labels. Counts appear only where something is waiting.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

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
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { search }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func count(_ destination: Destination) -> Int {
        switch destination {
        case .incoming: model.ingest.queued
        case .review: model.reviewCount
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
