import ArrumatorCore
import SwiftUI

/// Documents the app was not sure about. Each answer is a correction it learns from.
struct ReviewPage: View {
    @Environment(AppModel.self) private var model
    @State private var documents: [DocumentRecord] = []

    var body: some View {
        Page(.review, notes: documents.isEmpty ? nil : "Arrumator was not sure where these belong. Your answer teaches it.") {
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
