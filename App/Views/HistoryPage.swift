import ArrumatorCore
import SwiftUI

/// Everything that happened, newest first and grouped by day. An event about a document opens that document; one about
/// a search task opens the task.
struct HistoryPage: View {
    @Environment(AppModel.self) private var model
    @State private var events: [EventRecord] = []
    @State private var pages = 1
    @State private var openEvent: Int64?

    private var days: [(title: String, events: [EventRecord])] {
        var out: [(title: String, events: [EventRecord])] = []
        for event in events {
            let title = Wording.day(event.at)
            if out.last?.title == title { out[out.count - 1].events.append(event) } else { out.append((title, [event])) }
        }
        return out
    }

    /// Events about a search task that is still there to open.
    private static let taskEvents: Set<EventKind> = [.taskCreated, .taskPrepared, .taskFailed, .taskEdited, .taskExported]

    var body: some View {
        Page(.history) {
            if events.isEmpty {
                EmptyState(symbol: "clock", text: Wording.nothingHappened)
            }
            ForEach(days, id: \.title) { day in
                PageSection(day.title) {
                    ForEach(day.events) { event in
                        ListRow(symbol: EventStyle.symbol(event.kind), tint: EventStyle.color(event.kind), title: event.summary,
                                detail: event.at.formatted(date: .omitted, time: .shortened),
                                tag: event.actor == .user ? Wording.byYou : nil, wraps: true)
                            .onTapGesture {
                                if Self.taskEvents.contains(event.kind), let task = JSON.decode(TaskEventPayload.self, from: event.payloadJson)?.task {
                                    model.open(task: task)
                                    return
                                }
                                guard event.docId != nil else { return }
                                withAnimation(.snappy) { openEvent = openEvent == event.id ? nil : event.id }
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
            events = await model.load(Wording.loadHistoryAction) {
                try await $0.services.history.events(limit: pages * $0.config.interface.pageSize)
            } ?? []
        }
    }
}
