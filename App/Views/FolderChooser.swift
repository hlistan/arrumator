import ArrumatorCore
import SwiftUI

enum FolderChoice {
    case existing(Int64)
    case new(FolderSpec)
}

/// Pick an existing category or describe a new one (optionally in a new area).
struct FolderChooser: View {
    @Environment(AppModel.self) private var model
    let title: String
    let done: (FolderChoice?) -> Void
    @State private var taxonomy: TaxonomySnapshot?
    @State private var selected: Int64?
    @State private var creating = false
    @State private var area: String = ""
    @State private var newArea = ""
    @State private var name = ""
    @State private var description = ""
    @State private var yearly = false

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
                    Picker("Area", selection: $area) {
                        ForEach(taxonomy?.areas.filter { $0.origin != .system } ?? []) { Text("\($0.code) \($0.name)").tag($0.code) }
                        Text("New area…").tag("")
                    }
                    if area.isEmpty { TextField("New area name", text: $newArea) }
                    TextField("Folder name", text: $name)
                    TextField("What belongs here", text: $description, axis: .vertical).lineLimit(2...4)
                    Toggle("Split by year", isOn: $yearly)
                }
            } else {
                List(selection: $selected) {
                    ForEach(taxonomy?.areas ?? []) { area in
                        Section("\(area.code) \(area.name)") {
                            ForEach(taxonomy?.children(of: area.code).filter { $0.role == nil } ?? []) { f in
                                VStack(alignment: .leading) {
                                    Text("\(f.code) \(f.name)")
                                    Text(f.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .tag(f.id)
                            }
                        }
                    }
                }
                .frame(minHeight: 280)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(creating ? "Create and move" : "Move") {
                    if creating {
                        done(.new(FolderSpec(areaCode: area.isEmpty ? nil : area, newAreaName: area.isEmpty ? newArea : nil,
                                             newAreaDescription: area.isEmpty ? newArea : nil, name: name, description: description,
                                             yearSubfolders: yearly, yearRule: yearly ? .documentDate : nil)))
                    } else if let selected {
                        done(.existing(selected))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(creating ? name.isEmpty || (area.isEmpty && newArea.isEmpty) : selected == nil)
            }
        }
        .padding()
        .frame(width: 520)
        .task {
            guard let archive = model.settings?.archiveURL else { return }
            taxonomy = await model.load("Load folders") { try await $0.taxonomy.snapshot(root: archive) }
            area = taxonomy?.areas.first { $0.origin != .system }?.code ?? ""
        }
    }
}
