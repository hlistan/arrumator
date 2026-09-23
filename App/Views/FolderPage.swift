import ArrumatorCore
import SwiftUI

/// One folder of the archive, like a Things area or project: its description as the notes under the title, then its
/// folders (for an area) or its documents (for a category).
struct FolderPage: View {
    @Environment(AppModel.self) private var model
    let folderID: Int64
    @State private var documents: [DocumentRecord] = []
    @State private var editing = false

    private var folder: TaxonomyFolder? { model.taxonomy?.folder(id: folderID) }

    var body: some View {
        if let folder {
            Page(title: folder.name, symbol: folder.kind == .area ? "shippingbox.fill" : "folder.fill", tint: .secondary,
                 accessory: folder.code, notes: folder.description) {
                HStack(spacing: 14) {
                    Button("Edit Description…") { editing = true }
                    Button("Show in Finder") { if let taxonomy = model.taxonomy { model.open(taxonomy.url(for: folder).path) } }
                    Spacer()
                }
                .buttonStyle(.link)
                .font(.callout)
                if folder.kind == .area {
                    categories(of: folder)
                } else {
                    contents(of: folder)
                }
            }
            .task(id: model.activity) { await load(folder) }
            .sheet(isPresented: $editing) { FolderEditor(folder: folder) { editing = false }.environment(model) }
        } else {
            EmptyState(symbol: "folder", text: "This folder is no longer in the archive.")
        }
    }

    private func categories(of area: TaxonomyFolder) -> some View {
        let children = model.taxonomy?.children(of: area.code).filter { $0.role == nil } ?? []
        return PageSection("Folders") {
            if children.isEmpty {
                Text("No folders yet.").foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(children) { child in
                ListRow(symbol: "folder", tint: .secondary, title: child.name, detail: child.description)
                    .onTapGesture { model.go(.folder(child.id)) }
            }
        }
    }

    @ViewBuilder private func contents(of folder: TaxonomyFolder) -> some View {
        if !folder.learnedCorrespondents.isEmpty {
            Text("Usually from " + folder.learnedCorrespondents.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
        }
        if documents.isEmpty {
            EmptyState(symbol: "doc", text: "Nothing filed here yet.")
        } else {
            VStack(alignment: .leading, spacing: 0) { DocumentList(documents: documents, detail: .document) }
        }
    }

    private func load(_ folder: TaxonomyFolder) async {
        guard folder.kind != .area else { return }
        documents = await model.load("Load documents") {
            try await $0.services.documents.list(DocumentFilter(folderIDs: [folder.id]), order: .documentDate,
                                                 limit: $0.config.interface.pageSize)
        } ?? []
    }
}
