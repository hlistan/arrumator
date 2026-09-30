import ArrumatorCore
import SwiftUI

/// The menu bar popover: what the app is doing, whether anything needs you, and the last few decisions.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @State private var recent: [DocumentRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Arrumator").font(.headline)
                Spacer()
                Text(model.statusLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.settings?.onboardingCompleted == false {
                Button("Set Up Arrumator…") { model.show(.onboarding) }.buttonStyle(.borderedProminent)
            }
            if model.reviewCount > 0 {
                Button { model.open(document: nil, on: .review) } label: {
                    Label("\(model.reviewCount) need\(model.reviewCount == 1 ? "s" : "") you",
                          systemImage: Destination.review.symbol)
                        .foregroundStyle(Destination.review.tint)
                }
                .buttonStyle(.plain)
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recent, id: \.id) { document in
                        ListRow(symbol: document.status.symbol, tint: document.status.tint, title: document.filename,
                                subtitle: Wording.outcome(of: document, archive: model.settings?.archiveURL,
                                                          incoming: model.settings?.incomingURL))
                            .onTapGesture { model.open(document: document.id, on: .processed) }
                    }
                }
                .font(.callout)
            }
            Divider()
            HStack(spacing: 14) {
                Button("Open Arrumator") { model.show(.main) }
                Button(model.settings?.paused == true ? "Resume" : "Pause") { Task { await model.togglePause() } }
                Spacer()
                Menu {
                    Button("Open Incoming Folder") { if let path = model.settings?.incomingURL.path { model.open(path) } }
                    Button("Open Archive Folder") { if let path = model.settings?.archiveURL.path { model.open(path) } }
                    Divider()
                    Button("Settings…") { model.show(.settings) }
                    Button("Quit Arrumator") {
                        Task {
                            await model.runtime?.stop()
                            NSApp.terminate(nil)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 360)
        .task(id: model.activity) {
            recent = await model.load("Load processed documents") {
                try await $0.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed,
                                                     limit: $0.config.interface.menuBarRecent)
            } ?? []
        }
    }
}
