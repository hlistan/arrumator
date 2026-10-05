import ArrumatorCore
import SwiftUI

/// Documents waiting for the user: ones the model could not read, or that could not be filed. Each can be confirmed as
/// it is, corrected, or read again; one read again leaves the page for Incoming's queue, and the page says so, with a
/// way there, until another page is shown. Below them, apart and uncounted, those the user set aside: left for later, or
/// undone back into Incoming.
struct ReviewPage: View {
    @Environment(AppModel.self) private var model
    @State private var waiting: [ListedDocument] = []
    @State private var setAside: [ListedDocument] = []

    var body: some View {
        Page(.review, notes: waiting.isEmpty ? nil : Wording.reviewNotes) {
            if let readAgain = model.session.readAgain, !waiting.contains(where: { $0.id == readAgain.id }) {
                Notice(text: Wording.readAgainQueued(named: readAgain.name), action: (Wording.showIncoming, { model.go(.incoming) }))
            }
            if waiting.isEmpty {
                EmptyState(symbol: "checkmark.circle", text: Wording.nothingNeedsYou)
            } else {
                VStack(alignment: .leading, spacing: 0) { DocumentList(documents: waiting) }
            }
            if !setAside.isEmpty {
                PageSection(Wording.setAsideHeading) {
                    Text(Wording.setAsideNotes).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Style.sectionRuleGap)
                    DocumentList(documents: setAside)
                }
            }
        }
        .task(id: model.activity) {
            if let read = await model.load(Wording.loadReviewQueueAction, { try await $0.services.documents.needsYou() }) {
                waiting = model.listed(read.waiting)
                setAside = model.listed(read.setAside)
            }
        }
    }
}
