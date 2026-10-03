import ArrumatorCore
import SwiftUI

/// The documents that have every label chosen in the sidebar, by their own date, the newest first and the undated last
/// (`DocumentOrder.documentDate`), under a heading for each month of it and one for those without a date. The chosen
/// labels head the page, each can be let go of there as in the sidebar, and Clear beside them lets go of all.
struct LabelledPage: View {
    @Environment(AppModel.self) private var model
    /// The documents under the month of their own date, as the list shows them.
    @State private var sections: [DocumentSection] = []
    @State private var count = 0
    @State private var pages = 1

    var body: some View {
        let selection = model.session.labelSelection
        Page(title: selection.map(Wording.label).joined(separator: Wording.labelSeparator), symbol: Destination.labelled.symbol,
             tint: Destination.labelled.tint) {
            if let task = model.session.collecting { CollectingBar(task: task) }
            HStack(spacing: Style.chipSpacing) {
                ForEach(selection, id: \.self) { ChosenLabel(label: $0) }
                Button(Wording.clearLabels) { model.clearLabels() }
                    .buttonStyle(.link).font(.callout).help(Wording.clearLabelsHelp)
            }
            if count == 0 {
                EmptyState(symbol: "tag", text: Wording.noDocumentHasAll)
            }
            DocumentSections(sections: sections)
            if let pageSize = model.runtime?.config.interface.pageSize, count == pages * pageSize {
                Button(Wording.showMore) { pages += 1 }.buttonStyle(.link)
            }
        }
        .onChange(of: selection) { pages = 1 }
        .task(id: "\(pages)|\(selection)|\(model.activity)") {
            let pages = pages
            guard let loaded = await model.load(Wording.loadLabelledAction, { runtime in
                try await runtime.services.documents.list(DocumentFilter(labels: selection), order: .documentDate,
                                                          limit: pages * runtime.config.interface.pageSize)
            }) else { return }
            count = loaded.count
            sections = DocumentSection.sections(of: model.listed(loaded), heading: Wording.documentMonth)
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
            Button { model.choose(label) } label: {
                Image(systemName: "xmark.circle.fill").accessibilityLabel(Wording.letGoOf(Wording.label(label)))
            }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(Wording.showWithoutLabel)
        }
        .font(.callout)
        .padding(Style.chosenLabelInsets)
        .background(Style.hover, in: .capsule)
    }
}
