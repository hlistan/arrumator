import ArrumatorCore
import SwiftUI

/// The documents that have every label chosen in the sidebar, newest first and grouped by day, as on Processed. The
/// chosen labels head the page, each can be let go of there as in the sidebar, and Clear beside them lets go of all.
struct LabelledPage: View {
    @Environment(AppModel.self) private var model
    @State private var documents: [DocumentRecord] = []
    @State private var pages = 1

    var body: some View {
        let selection = model.labelSelection
        Page(title: selection.map(Wording.label).joined(separator: Wording.labelSeparator), symbol: Destination.labelled.symbol,
             tint: Destination.labelled.tint) {
            if let task = model.collecting { CollectingBar(task: task) }
            HStack(spacing: Style.chipSpacing) {
                ForEach(selection, id: \.self) { ChosenLabel(label: $0) }
                Button(Wording.clearLabels) { model.clearLabels() }
                    .buttonStyle(.link).font(.callout).help(Wording.clearLabelsHelp)
            }
            if documents.isEmpty {
                EmptyState(symbol: "tag", text: Wording.noDocumentHasAll)
            }
            ProcessedDays(documents: documents)
            if let pageSize = model.runtime?.config.interface.pageSize, documents.count == pages * pageSize {
                Button(Wording.showMore) { pages += 1 }.buttonStyle(.link)
            }
        }
        .onChange(of: selection) { pages = 1 }
        .task(id: "\(pages)|\(selection)|\(model.activity)") {
            let pages = pages
            guard let loaded = await model.load(Wording.loadLabelledAction, { runtime in
                try await runtime.services.documents.list(DocumentFilter(labels: selection), order: .recentlyProcessed,
                                                          limit: pages * runtime.config.interface.pageSize)
            }) else { return }
            documents = loaded
        }
    }
}

/// A label chosen in the sidebar, by its kind, with a way to let go of it.
private struct ChosenLabel: View {
    @Environment(AppModel.self) private var model
    let label: DocumentLabel

    var body: some View {
        HStack(spacing: Style.chipContentSpacing) {
            Text(Wording.labelKind(label.kind)).foregroundStyle(.secondary)
            Text(Wording.label(label))
            Button { model.choose(label) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(Wording.showWithoutLabel)
        }
        .font(.callout)
        .padding(Style.chosenLabelInsets)
        .background(Style.hover, in: .capsule)
    }
}
