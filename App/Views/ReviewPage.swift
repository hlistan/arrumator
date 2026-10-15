import ArrumatorCore
import SwiftUI

/// Documents waiting for the user: ones the model could not read, or that could not be filed. Each can be confirmed as
/// it is, corrected, or read again; one read again leaves the page for Incoming's queue, and the page says so, with a
/// way there, for as long as Core says a reading of it is queued or under way (`JobStore.beingRead`): not once the
/// reading has ended, whatever page was shown meanwhile, and never after Leave for Later or a reading that failed. Below them, apart and uncounted, those the user set aside: left for later, or
/// undone back into Incoming.
struct ReviewPage: View {
    @Environment(AppModel.self) private var model
    @State private var waiting: [ListedDocument] = []
    @State private var setAside: [ListedDocument] = []
    /// Which of the documents asked to be read again have a reading queued or under way, as Core says it.
    @State private var beingRead: Set<Int64> = []

    var body: some View {
        let pageOrder = (waiting + setAside).compactMap(\.id)
        Page(.review, notes: waiting.isEmpty ? nil : Wording.reviewNotes) {
            RemovedNotice()
            if let readAgain = model.session.readAgain, beingRead.contains(readAgain.id), !waiting.contains(where: { $0.id == readAgain.id }) {
                Notice(text: Wording.readAgainQueued(named: readAgain.name), action: (Wording.showIncoming, { model.go(.incoming) }))
            }
            if waiting.isEmpty {
                EmptyState(symbol: "checkmark.circle", text: Wording.nothingNeedsYou)
            } else {
                VStack(alignment: .leading, spacing: 0) { DocumentList(documents: waiting, pageOrder: pageOrder) }
            }
            if !setAside.isEmpty {
                PageSection(Wording.setAsideHeading, lazily: !setAside.contains { $0.id == model.session.openDocument }) {
                    Text(Wording.setAsideNotes).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Style.sectionRuleGap)
                    DocumentList(documents: setAside, pageOrder: pageOrder)
                }
            }
        }
        // Reloaded as the worker takes and ends the reading, with no change of page, and as one is asked for.
        .task(id: "\(model.ingestActivity)|\(model.session.readAgain?.id ?? 0)") {
            let asked = model.session.readAgain?.id
            if let ((read, queued), refusals) = await model.load(Wording.loadReviewQueueAction, withRefusals: { runtime in
                let read = try await runtime.services.documents.needsYou()
                let queued = try await runtime.services.jobs.beingRead(asked.map { [$0] } ?? [])
                return ((read, queued), read.waiting + read.setAside)
            }) {
                waiting = model.listed(read.waiting, refusals: refusals)
                setAside = model.listed(read.setAside, refusals: refusals)
                beingRead = queued
                // A reading that has ended leaves nothing to say, on this page or a later one (`go(_:)` clears it too).
                if let asked, !queued.contains(asked), model.session.readAgain?.id == asked { model.session.readAgain = nil }
            }
        }
    }
}
