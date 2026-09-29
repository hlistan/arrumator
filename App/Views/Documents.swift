import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// Documents the way Things lists to-dos: one line each, what happened to it at the end, its labels beneath, and a
/// click opens the document in place as a card.
struct DocumentList: View {
    @Environment(AppModel.self) private var model
    let documents: [DocumentRecord]
    var snippets: [Int64: String] = [:]

    var body: some View {
        ForEach(documents, id: \.id) { document in
            if let id = document.id, model.openDocument == id {
                DocumentCard(documentID: id)
            } else {
                row(document)
                    .onTapGesture { withAnimation(.snappy) { model.openDocument = document.id } }
            }
        }
    }

    private func row(_ d: DocumentRecord) -> some View {
        let subtitle = d.id.flatMap { snippets[$0] }?.replacingOccurrences(of: "\n", with: " ") ?? Wording.labels(d.labels)
        return ListRow(symbol: d.status.symbol, tint: d.status.tint, title: d.filename,
                       detail: Wording.outcome(of: d, archive: model.settings?.archiveURL, incoming: model.settings?.incomingURL),
                       subtitle: subtitle)
    }
}

/// A document opened in place: its labels, all it is described by, who read it, and every way to correct it. Each
/// change goes through `ReviewActions`, which records it.
struct DocumentCard: View {
    @Environment(AppModel.self) private var model
    let documentID: Int64
    @State private var document: DocumentRecord?
    @State private var name = ""
    @State private var newKind = LabelKind.topic
    @State private var newValue = ""
    @State private var showingTrace = false
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let document {
                header(document)
                labels(document)
                reading(document)
                actions(document)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(Style.cardPadding)
        .background(Style.card, in: .rect(cornerRadius: Style.cardCornerRadius))
        .shadow(color: Style.cardShadow, radius: Style.cardShadowRadius, y: Style.cardShadowOffset)
        .padding(.vertical, 8)
        .onExitCommand { close() }
        .task(id: model.activity) { await load() }
        .onChange(of: editingName) { wasEditing, _ in
            if wasEditing { Task { await rename() } }
        }
        .sheet(isPresented: $showingTrace) {
            TraceView(documentID: documentID).environment(model).frame(minWidth: 760, minHeight: 560)
        }
    }

    // MARK: Parts

    private func header(_ d: DocumentRecord) -> some View {
        HStack(alignment: .top, spacing: 16) {
            FileThumbnail(url: d.url, size: Style.thumbnail)
                .onTapGesture(count: 2) { model.open(d.path) }
                .help("Double-click to open")
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .focused($editingName)
                    .onSubmit { editingName = false }
                placement(d)
                Text("Arrived as \(d.originalFilename) · \(d.addedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Close")
        }
    }

    /// Where it is, or what happened to it.
    private func placement(_ d: DocumentRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: d.status.symbol).foregroundStyle(d.status.tint)
            Text(Wording.outcome(of: d, archive: model.settings?.archiveURL, incoming: model.settings?.incomingURL))
        }
        .font(.callout)
    }

    /// Every label, one row per kind it has, each removable, and a way to add one.
    private func labels(_ d: DocumentRecord) -> some View {
        let labels = d.labels ?? []
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(LabelKind.allCases.filter { kind in labels.contains { $0.kind == kind } }, id: \.self) { kind in
                GridRow(alignment: .firstTextBaseline) {
                    label(Wording.labelKind(kind))
                    HStack(spacing: 6) {
                        ForEach(labels.filter { $0.kind == kind }, id: \.self) { item in
                            LabelChip(label: item) { save(labels.filter { $0 != item }) }
                        }
                    }
                }
            }
            GridRow(alignment: .firstTextBaseline) {
                label(labels.isEmpty ? "Labels" : "")
                HStack(spacing: 6) {
                    Picker("Kind", selection: $newKind) {
                        ForEach(LabelKind.allCases, id: \.self) { Text(Wording.labelKind($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: Style.labelKindPickerWidth)
                    TextField(Wording.labelPrompt(newKind), text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { add(to: labels) }
                    Button("Add") { add(to: labels) }
                        .disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
        }
    }

    /// Who read the document, and anything that keeps it waiting for the user.
    @ViewBuilder private func reading(_ d: DocumentRecord) -> some View {
        if let analysis = d.analysis {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow(alignment: .firstTextBaseline) {
                    label("Read")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Wording.reader(analysis))
                        ForEach(analysis.problems, id: \.self) { problem in
                            Text(problem).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func actions(_ d: DocumentRecord) -> some View {
        HStack(spacing: 14) {
            Button("Open") { model.open(d.path) }
            Button("Show in Finder") { model.reveal(d.path) }
            Button("How Was This Read?") { showingTrace = true }
            Spacer()
            switch d.status {
            case .filed:
                Button("Undo Filing") { run("Undo") { try await $0.review.undo(documentID) } }
                    .help("Move it back to Incoming")
                Button("Looks Right") { run("Confirm") { try await $0.review.confirm(documentID) } }
                    .help("Confirm its name and labels")
            case .needsReview, .failed:
                Button("Leave for Later") { run("Hold") { try await $0.review.hold(documentID) } }
                Button("Read Again") { run("Read again") { try await $0.review.retry(documentID) } }
                Button("Looks Right") { run("Confirm") { try await $0.review.confirm(documentID) } }
                    .help("Keep it in the archive as it is")
            case .held, .undone:
                Button("Read Again") { run("Read again") { try await $0.review.retry(documentID) } }
            default:
                EmptyView()
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    // MARK: Changes

    /// Adds the label being typed; one of a single-valued kind takes the place of the one there.
    private func add(to labels: [DocumentLabel]) {
        let value = newValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        let kept = newKind.isSingle ? labels.filter { $0.kind != newKind } : labels
        save(kept + [DocumentLabel(kind: newKind, value: value)])
        newValue = ""
    }

    private func save(_ labels: [DocumentLabel]) {
        run("Change labels") { try await $0.review.edit(documentID, fileName: nil, labels: labels) }
    }

    /// Renames the file when the user leaves the name, as Things saves a field; an unchanged name is left alone.
    private func rename() async {
        guard let d = document else { return }
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != (d.filename as NSString).deletingPathExtension else { return }
        await model.perform("Rename") { try await $0.review.edit(documentID, fileName: value, labels: nil) }
    }

    private func run(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> Void) {
        Task { await model.perform(what, action) }
    }

    private func close() {
        withAnimation(.snappy) { if model.openDocument == documentID { model.openDocument = nil } }
    }

    private func load() async {
        document = await model.load("Load document") { try await $0.services.documents.document(id: documentID) } ?? nil
        guard let document, !editingName else { return }
        name = (document.filename as NSString).deletingPathExtension
    }
}

/// One label on a card; under the pointer, a × takes it off the document.
struct LabelChip: View {
    let label: DocumentLabel
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(Wording.label(label)).textSelection(.enabled)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this label")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Style.hover, in: .capsule)
        .onHover { hovering = $0 }
    }
}
