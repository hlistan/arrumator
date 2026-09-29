import ArrumatorCore
import SwiftUI

enum FolderChoice {
    case existing(Int64)
    case new(FolderSpec)
}

/// Pick any folder of the tree, or name a new one inside any folder or at the top of the archive.
struct FolderChooser: View {
    @Environment(AppModel.self) private var model
    let title: String
    let done: (FolderChoice?) -> Void
    @State private var taxonomy: TaxonomySnapshot?
    @State private var selected: Int64?
    @State private var creating = false
    /// The folder a new one goes in; the top of the archive when empty.
    @State private var parent = ""
    @State private var name = ""
    @State private var description = ""
    @State private var yearly = false

    private var tree: [(folder: TaxonomyFolder, depth: Int)] { taxonomy?.outline(include: \.holdsUserDocuments) ?? [] }

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.title3.bold())
            Picker("", selection: $creating) {
                Text("Existing folder").tag(false)
                Text("New folder").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if creating {
                Form {
                    Picker("Inside", selection: $parent) {
                        Text("Top of the archive").tag("")
                        ForEach(tree, id: \.folder.id) { item in
                            Text(taxonomy.map { Wording.path(of: item.folder, in: $0) } ?? item.folder.name).tag(item.folder.code)
                        }
                    }
                    TextField("Folder name", text: $name)
                    TextField("What belongs here", text: $description, axis: .vertical).lineLimit(2...4)
                    Toggle("Split by year", isOn: $yearly)
                }
            } else {
                List(selection: $selected) {
                    ForEach(tree, id: \.folder.id) { item in
                        VStack(alignment: .leading) {
                            Text(item.folder.name)
                            if !item.folder.description.isEmpty {
                                Text(item.folder.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.leading, CGFloat(item.depth - 1) * Style.outlineIndent)
                        .tag(item.folder.id)
                    }
                }
                .frame(minHeight: 280)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(creating ? "Create and move" : "Move") {
                    if creating {
                        done(.new(FolderSpec(parentCode: parent.isEmpty ? nil : parent,
                                             levels: [FolderLevel(name: name, description: description)],
                                             yearSubfolders: yearly, yearRule: yearly ? .documentDate : nil)))
                    } else if let selected {
                        done(.existing(selected))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(creating ? name.trimmingCharacters(in: .whitespaces).isEmpty : selected == nil)
            }
        }
        .padding()
        .frame(width: 520)
        .task {
            guard let archive = model.settings?.archiveURL else { return }
            taxonomy = await model.load("Load folders") { try await $0.taxonomy.snapshot(root: archive) }
        }
    }
}
