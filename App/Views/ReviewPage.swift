import ArrumatorCore
import SwiftUI

/// Documents waiting for the user: ones the model could not read, and ones left for later. Each can be confirmed as
/// it is, corrected, or read again.
struct ReviewPage: View {
    @Environment(AppModel.self) private var model
    @State private var documents: [DocumentRecord] = []

    var body: some View {
        Page(.review, notes: documents.isEmpty ? nil : "Arrumator could not read these as it should. Confirm one as it is, "
            + "correct its name and details, or have it read again.") {
            if documents.isEmpty {
                EmptyState(symbol: "checkmark.circle", text: "Nothing needs you.")
            } else {
                VStack(alignment: .leading, spacing: 0) { DocumentList(documents: documents) }
            }
        }
        .task(id: model.activity) {
            documents = await model.load("Load review queue") { try await $0.services.documents.reviewQueue() } ?? []
        }
    }
}
