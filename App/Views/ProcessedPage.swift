import ArrumatorCore
import SwiftUI

/// Everything the pipeline has finished with, newest first and grouped by day, like Things' Logbook. Every row shows
/// where the document is and its labels; opening one lets you correct it.
struct ProcessedPage: View {
    @Environment(AppModel.self) private var model
    @State private var documents: [DocumentRecord] = []
    /// `documents` under the day each was processed, as the list shows them.
    @State private var sections: [DocumentSection] = []
    @State private var pages = 1

    var body: some View {
        Page(.processed, notes: Wording.processedNotes) {
            RemovedNotice()
            if let task = model.session.collecting { CollectingBar(task: task) }
            if documents.isEmpty {
                EmptyState(symbol: "checkmark.circle", text: Wording.nothingProcessed)
            }
            DocumentSections(sections: sections)
            if let pageSize = model.runtime?.config.interface.pageSize, documents.count == pages * pageSize {
                Button(Wording.showMore) { pages += 1 }.buttonStyle(.link)
            }
        }
        .task(id: "\(pages)|\(model.activity)|\(model.session.openDocument == nil)") {
            let pages = pages
            let cardOpen = model.session.openDocument != nil && !documents.isEmpty
            let shown = cardOpen ? documents.compactMap(\.id) : []
            guard let ((loaded, gone), refusals) = await model.load(Wording.loadProcessedAction, withRefusals: { runtime in
                let loaded = try await runtime.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed,
                                                                       limit: pages * runtime.config.interface.pageSize)
                // A row kept under an open card that the page no longer lists is gone only if the index no longer has it: a
                // document filed meanwhile pushes the last row off the page, which is still a document.
                let listed = Set(loaded.compactMap(\.id))
                let missing = shown.filter { !listed.contains($0) }
                let kept = Set(try await runtime.services.documents.documents(ids: missing).compactMap(\.id))
                return ((loaded, Set(missing).subtracting(kept)), loaded)
            }) else { return }
            // While a card is open, the rows keep their places, each brought up to date, and one that left the index (it
            // was removed from another row) leaves the list: a document filed meanwhile would go in above and move the
            // card from under the reader. It shows once the card is closed.
            if cardOpen {
                let byID = Dictionary(loaded.compactMap { d in d.id.map { ($0, d) } }, uniquingKeysWith: { first, _ in first })
                documents = documents.compactMap { d in
                    guard let id = d.id else { return d }
                    return byID[id] ?? (gone.contains(id) ? nil : d)
                }
            } else {
                documents = loaded
            }
            sections = DocumentSection.sections(of: model.listed(documents, refusals: refusals), heading: Wording.processedDay)
        }
    }
}
