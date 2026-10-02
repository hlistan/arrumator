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
        .task(id: "\(pages)|\(model.activity)|\(model.openDocument == nil)") {
            let pages = pages
            guard let loaded = await model.load(Wording.loadProcessedAction, {
                try await $0.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed,
                                                     limit: pages * $0.config.interface.pageSize)
            }) else { return }
            // While a card is open, the rows keep their places, each brought up to date: a document filed meanwhile would
            // go in above and move the card from under the reader. It shows once the card is closed.
            if model.openDocument != nil, !documents.isEmpty {
                let byID = Dictionary(loaded.compactMap { d in d.id.map { ($0, d) } }, uniquingKeysWith: { first, _ in first })
                documents = documents.map { d in d.id.flatMap { byID[$0] } ?? d }
            } else {
                documents = loaded
            }
        }
    }
}
