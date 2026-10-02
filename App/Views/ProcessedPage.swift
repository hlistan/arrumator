import ArrumatorCore
import SwiftUI

/// Everything the pipeline has finished with, newest first and grouped by day, like Things' Logbook. Every row shows
/// where the document is and its labels; opening one lets you correct it.
struct ProcessedPage: View {
    @Environment(AppModel.self) private var model
    @State private var documents: [DocumentRecord] = []
    @State private var pages = 1

    var body: some View {
        Page(.processed) {
            if let task = model.collecting { CollectingBar(task: task) }
            if documents.isEmpty {
                EmptyState(symbol: "checkmark.circle", text: Wording.nothingProcessed)
            }
            DocumentSections(documents: documents, heading: Wording.processedDay)
            if let pageSize = model.runtime?.config.interface.pageSize, documents.count == pages * pageSize {
                Button(Wording.showMore) { pages += 1 }.buttonStyle(.link)
            }
        }
        .task(id: "\(pages)|\(model.activity)") {
            let pages = pages
            documents = await model.load(Wording.loadProcessedAction) {
                try await $0.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed,
                                                     limit: pages * $0.config.interface.pageSize)
            } ?? []
        }
    }
}
