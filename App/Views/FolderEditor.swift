import ArrumatorCore
import SwiftUI

/// Edits a folder's description; the model reads it when deciding where documents go.
struct FolderEditor: View {
    @Environment(AppModel.self) private var model
    let folder: TaxonomyFolder
    let done: () -> Void
    @State private var description = ""
    @State private var details = ""
    @State private var yearly = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(model.taxonomy.map { Wording.path(of: folder, in: $0) } ?? folder.name).font(.title3.bold())
            Text("Describe what belongs here and what does not. Arrumator reads this when deciding where new files go.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Description", text: $description, axis: .vertical).lineLimit(3...6)
            Text("Details (Markdown)").font(.caption)
            TextEditor(text: $details).font(.body.monospaced()).frame(minHeight: 180)
            Toggle("Split into year folders", isOn: $yearly)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    let (description, details, yearly) = (description, details, yearly)
                    let folder = folder
                    Task {
                        await model.perform("Save description") { runtime in
                            let settings = await runtime.settings.current
                            let def = FolderDefinition(code: folder.code, name: folder.name, role: folder.role,
                                                       description: description, yearSubfolders: yearly,
                                                       yearRule: yearly ? folder.yearRule : nil, autoFile: folder.autoFile || folder.origin == .inferred,
                                                       origin: .user)
                            try await runtime.taxonomy.updateDescription(folderID: folder.id, root: settings.archiveURL, definition: def,
                                                                         body: details, actor: .user)
                        }
                        done()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560)
        .onAppear {
            description = folder.description
            details = folder.body
            yearly = folder.yearSubfolders
        }
    }
}
