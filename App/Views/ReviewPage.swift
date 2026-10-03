import ArrumatorCore
import SwiftUI

/// Documents waiting for the user: ones the model could not read, and ones left for later. Each can be confirmed as
/// it is, corrected, or read again.
struct ReviewPage: View {
    @Environment(AppModel.self) private var model
    @State private var documents: [ListedDocument] = []

    var body: some View {
        Page(.review, notes: documents.isEmpty ? nil : Wording.reviewNotes) {
            if documents.isEmpty {
                EmptyState(symbol: "checkmark.circle", text: Wording.nothingNeedsYou)
            } else {
                VStack(alignment: .leading, spacing: 0) { DocumentList(documents: documents) }
            }
        }
        .task(id: model.activity) {
            if let read = await model.load(Wording.loadReviewQueueAction, { try await $0.services.documents.reviewQueue() }) { documents = model.listed(read) }
        }
    }
}
