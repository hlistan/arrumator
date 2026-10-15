import ArrumatorCore
import SwiftUI

/// Everything that happened, newest first and grouped by day. An event about a document opens that document; one about
/// a search task opens the task.
struct HistoryPage: View {
    @Environment(AppModel.self) private var model
    /// Each event with the name its document has now, as Core lists it (`HistoryStore.listed`).
    @State private var events: [ListedEvent] = []
    @State private var pages = 1
    @State private var openEvent: Int64?
    /// Why each removal among `events` cannot be put back now, as read with them (`ReviewActions.putBackRefusals`).
    @State private var refusals: [Int64: PutBackError] = [:]

    private var days: [(title: String, events: [ListedEvent])] {
        var out: [(title: String, events: [ListedEvent])] = []
        for event in events {
            let title = Wording.day(event.event.at)
            if out.last?.title == title { out[out.count - 1].events.append(event) } else { out.append((title, [event])) }
        }
        return out
    }

    /// Events about a search task that is still there to open.
    private static let taskEvents: Set<EventKind> = [.taskCreated, .taskPrepared, .taskFailed, .taskEdited, .taskExported]

    var body: some View {
        Page(.history) {
            RemovedNotice()
            if events.isEmpty {
                EmptyState(symbol: "clock", text: Wording.nothingHappened)
            }
            ForEach(days, id: \.title) { day in
                PageSection(day.title, lazily: !day.events.contains { $0.id == openEvent }) {
                    ForEach(day.events) { listed in
                        let event = listed.event
                        let row = ListRow(symbol: EventStyle.symbol(event.kind), tint: EventStyle.color(event.kind), title: event.summary,
                                          detail: Wording.historyDetail(document: listed.document, at: event.at),
                                          tag: event.actor == .user ? Wording.byYou : nil, wraps: true)
                        let open = {
                            if Self.taskEvents.contains(event.kind), let task = JSON.decode(TaskEventPayload.self, from: event.payloadJson)?.task {
                                model.open(task: task)
                                return
                            }
                            guard event.docId != nil else { return }
                            withAnimation(.snappy) { openEvent = openEvent == event.id ? nil : event.id }
                        }
                        if event.kind == .documentRemoved, let id = event.id {
                            RemovalRow(row: row.rowAction(open), event: id, refusal: refusals[id])
                        } else {
                            row.rowAction(open)
                        }
                        if openEvent == event.id, let doc = event.docId {
                            DocumentCard(documentID: doc) { openEvent = nil }
                        }
                    }
                }
            }
            if let pageSize = model.runtime?.config.interface.pageSize, events.count == pages * pageSize {
                Button(Wording.showMore) { pages += 1 }.buttonStyle(.link)
            }
        }
        .task(id: "\(pages)|\(model.activity)") {
            let pages = pages
            if let (read, refused) = await model.load(Wording.loadHistoryAction, { runtime in
                let read = try await runtime.services.history.listed(limit: pages * runtime.config.interface.pageSize)
                return (read, try await runtime.review.putBackRefusals(of: read.map(\.event).filter { $0.kind == .documentRemoved }))
            }) {
                events = read
                refusals = refused
            }
        }
    }
}

/// The row of a document removed: under the pointer a Put Back button, and the same in its context menu and as an
/// accessibility action (`ReviewActions.putBack`). When Core would refuse (`PutBackRule`), all three are dimmed with why,
/// and the action says why to VoiceOver instead of acting.
private struct RemovalRow<Row: View>: View {
    @Environment(AppModel.self) private var model
    let row: Row
    let event: Int64
    let refusal: PutBackError?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Style.rowAccessorySpacing) {
            row
            Button(Wording.putBack, action: putBack)
                .buttonStyle(.link).disabled(refusal != nil).help(help)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .accessibilityAction(named: Wording.putBack) {
            if let refusal {
                AccessibilityNotification.Announcement(Wording.reason(refusal)).post()
            } else {
                putBack()
            }
        }
        .contextMenu { Button(Wording.putBack, action: putBack).disabled(refusal != nil).help(help) }
    }

    private var help: String { refusal.map(Wording.reason) ?? Wording.putBackHelp }

    private func putBack() {
        let event = event
        Task<Void, Never> { await model.putBack(removal: event) }
    }
}
