import ArrumatorCore
import SwiftUI

/// Everything the pipeline has finished with, newest first and grouped by day, like Things' Logbook. Every row shows
/// the decision; opening one lets you change it.
struct ProcessedPage: View {
    @Environment(AppModel.self) private var model
    @State private var documents: [DocumentRecord] = []
    @State private var pages = 1

    var body: some View {
        Page(.processed) {
            if documents.isEmpty {
                EmptyState(symbol: "checkmark.circle", text: "Nothing has been processed yet.")
            }
            ProcessedDays(documents: documents)
            if let pageSize = model.runtime?.config.interface.pageSize, documents.count == pages * pageSize {
                Button("Show More") { pages += 1 }.buttonStyle(.link)
            }
        }
        .task(id: "\(pages)|\(model.activity)") {
            let pages = pages
            documents = await model.load("Load processed documents") {
                try await $0.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed,
                                                     limit: pages * $0.config.interface.pageSize)
            } ?? []
        }
    }
}

/// Processed documents under the day they were processed, newest first: the Processed page, and what was just
/// processed on the Incoming page, read the same way.
struct ProcessedDays: View {
    let documents: [DocumentRecord]

    private var days: [(title: String, documents: [DocumentRecord])] {
        var out: [(title: String, documents: [DocumentRecord])] = []
        for document in documents {
            let title = Wording.day(Wording.processedAt(document))
            if out.last?.title == title { out[out.count - 1].documents.append(document) } else { out.append((title, [document])) }
        }
        return out
    }

    var body: some View {
        ForEach(days, id: \.title) { day in
            PageSection(day.title) { DocumentList(documents: day.documents) }
        }
    }
}
