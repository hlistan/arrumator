import ArrumatorCore
import SwiftUI

/// The documents that have every label chosen in the sidebar, newest first and grouped by day, as on Processed. The
/// chosen labels head the page, and each can be let go of there as in the sidebar.
struct LabelledPage: View {
    @Environment(AppModel.self) private var model
    @State private var documents: [DocumentRecord] = []
    @State private var pages = 1

    var body: some View {
        let selection = model.labelSelection
        Page(title: selection.map(Wording.label).joined(separator: " · "), symbol: Destination.labelled.symbol,
             tint: Destination.labelled.tint) {
            HStack(spacing: 6) {
                ForEach(selection, id: \.self) { ChosenLabel(label: $0) }
            }
            if documents.isEmpty {
                EmptyState(symbol: "tag", text: "No document has every one of these labels.")
            }
            ProcessedDays(documents: documents)
            if let pageSize = model.runtime?.config.interface.pageSize, documents.count == pages * pageSize {
                Button("Show More") { pages += 1 }.buttonStyle(.link)
            }
        }
        .onChange(of: selection) { pages = 1 }
        .task(id: "\(pages)|\(selection)|\(model.activity)") {
            let pages = pages
            guard let loaded = await model.load("Load labelled documents", { runtime in
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
        HStack(spacing: 4) {
            Text(Wording.labelKind(label.kind)).foregroundStyle(.secondary)
            Text(Wording.label(label))
            Button { model.choose(label) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Show documents without this label too")
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Style.hover, in: .capsule)
    }
}
