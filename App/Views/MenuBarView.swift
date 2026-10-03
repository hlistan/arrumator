import ArrumatorCore
import SwiftUI

/// The menu bar popover: what the app is doing, whether anything needs you, and the last few decisions.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @State private var recent: [ListedDocument] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Style.menuBarSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(Wording.appName).font(.headline)
                Spacer()
                Text(model.statusLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.settings?.onboardingCompleted == false {
                Button(Wording.setUpApp) { model.show(.onboarding) }.buttonStyle(.borderedProminent)
            }
            if model.session.reviewCount > 0 {
                Button { model.open(document: nil, on: .review) } label: {
                    Label(Wording.needYou(model.session.reviewCount),
                          systemImage: Destination.review.symbol)
                        .foregroundStyle(Destination.review.tint)
                }
                .buttonStyle(.plain)
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: Style.menuBarRecentSpacing) {
                    ForEach(recent) { document in
                        ListRow(symbol: document.record.status.symbol, tint: document.record.status.tint, title: document.record.filename,
                                subtitle: document.outcome)
                            .rowAction { model.open(document: document.id, on: .processed) }
                    }
                }
                .font(.callout)
            }
            Divider()
            HStack(spacing: Style.actionSpacing) {
                Button(Wording.openApp) { model.show(.main) }
                Button(model.settings?.paused == true ? Wording.resume : Wording.pause) {
                    let paused = model.settings?.paused == true
                    Task { await model.setPaused(!paused) }
                }
                Spacer()
                Menu {
                    Button(Wording.openIncomingFolder) { if let path = model.settings?.incomingURL.path { model.open(path) } }
                    Button(Wording.openArchiveFolder) { if let path = model.archive?.path { model.open(path) } }
                    Divider()
                    Button(Wording.settings) { model.show(.settings) }
                    // Quits as the app menu's Quit does: the app delegate stops the work first, for a bounded time
                    // (`applicationShouldTerminate`), so every way to quit takes that one path.
                    Button(Wording.quitApp) { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(Wording.moreActions).help(Wording.moreActions)
            }
            .buttonStyle(.borderless)
        }
        .padding(Style.menuBarPadding)
        .frame(width: Style.popover.width)
        .task(id: model.activity) {
            if let read = await model.load(Wording.loadProcessedAction, {
                try await $0.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed,
                                                     limit: $0.config.interface.menuBarRecent)
            }) { recent = model.listed(read) }
        }
    }
}
