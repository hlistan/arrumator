import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// Documents the way Things lists to-dos: one line each, what happened to it at the end, its labels beneath, and a
/// click opens the document in place as a card. While documents are added to a search task, each row ends with a button
/// that adds it to the task's set or takes it out.
struct DocumentList: View {
    @Environment(AppModel.self) private var model
    let documents: [DocumentRecord]

    var body: some View {
        ForEach(documents, id: \.id) { document in
            if let id = document.id, model.openDocument == id {
                DocumentCard(documentID: id) { if model.openDocument == id { model.openDocument = nil } }
            } else {
                HStack(spacing: Style.rowAccessorySpacing) {
                    row(document)
                        .onTapGesture { withAnimation(.snappy) { model.openDocument = document.id } }
                    if let task = model.collecting, let id = document.id {
                        CollectToggle(task: task, document: id)
                    }
                }
            }
        }
    }

    private func row(_ d: DocumentRecord) -> some View {
        ListRow(symbol: d.status.symbol, tint: d.status.tint, title: d.filename,
                detail: Wording.outcome(of: d, archive: model.settings?.archiveURL, incoming: model.settings?.incomingURL),
                subtitle: Wording.labels(d.labels))
    }
}

/// A document opened in place: its labels, all it is described by, who read it, and every way to correct it. Each
/// change goes through `ReviewActions`, which records it.
struct DocumentCard: View {
    @Environment(AppModel.self) private var model
    let documentID: Int64
    /// Closes the card on the page that opened it; each page keeps its own open card.
    let onClose: () -> Void
    @State private var document: DocumentRecord?
    @State private var name = ""
    @State private var newKind = LabelKind.topic
    @State private var newValue = ""
    @State private var showingTrace = false
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Style.documentCardSpacing) {
            if let document {
                header(document)
                labels(document)
                reading(document)
                actions(document)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .card()
        .onExitCommand { close() }
        .task(id: model.activity) { await load() }
        .onChange(of: editingName) { wasEditing, _ in
            if wasEditing { Task { await rename() } }
        }
        .sheet(isPresented: $showingTrace) {
            TraceView(documentID: documentID).environment(model).frame(minWidth: Style.traceSheetMinimum.width, minHeight: Style.traceSheetMinimum.height)
        }
    }

    // MARK: Parts

    private func header(_ d: DocumentRecord) -> some View {
        HStack(alignment: .top, spacing: Style.thumbnailSpacing) {
            FileThumbnail(url: d.url, size: Style.thumbnail)
                .onTapGesture(count: 2) { model.open(d.path) }
                .help(Wording.doubleClickToOpen)
            VStack(alignment: .leading, spacing: Style.cardHeaderSpacing) {
                TextField(Wording.name, text: $name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .focused($editingName)
                    .onSubmit { editingName = false }
                placement(d)
                Text(Wording.arrived(as: d.originalFilename, at: d.addedAt))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(Wording.close)
        }
    }

    /// Where it is, or what happened to it.
    private func placement(_ d: DocumentRecord) -> some View {
        HStack(spacing: Style.placementSpacing) {
            Image(systemName: d.status.symbol).foregroundStyle(d.status.tint)
            Text(Wording.outcome(of: d, archive: model.settings?.archiveURL, incoming: model.settings?.incomingURL))
        }
        .font(.callout)
    }

    /// Every label, one row per kind it has, each removable, and a way to add one.
    private func labels(_ d: DocumentRecord) -> some View {
        let labels = d.labels ?? []
        return Grid(alignment: .leading, horizontalSpacing: Style.cardGridColumnSpacing, verticalSpacing: Style.cardLabelRowSpacing) {
            ForEach(LabelKind.allCases.filter { kind in labels.contains { $0.kind == kind } }, id: \.self) { kind in
                GridRow(alignment: .firstTextBaseline) {
                    label(Wording.labelKind(kind))
                    HStack(spacing: Style.chipSpacing) {
                        ForEach(labels.filter { $0.kind == kind }, id: \.self) { item in
                            LabelChip(label: item) { save(labels.filter { $0 != item }) }
                        }
                    }
                }
            }
            GridRow(alignment: .firstTextBaseline) {
                label(labels.isEmpty ? Wording.labelsHeading : "")
                HStack(spacing: Style.inlineControlSpacing) {
                    Picker(Wording.labelKindPicker, selection: $newKind) {
                        ForEach(LabelKind.allCases, id: \.self) { Text(Wording.labelKind($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: Style.labelKindPickerWidth)
                    TextField(Wording.labelPrompt(newKind), text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { add(to: labels) }
                    Button(Wording.add) { add(to: labels) }
                        .disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
        }
    }

    /// Who read the document, and anything that keeps it waiting for the user.
    @ViewBuilder private func reading(_ d: DocumentRecord) -> some View {
        if let analysis = d.analysis {
            Grid(alignment: .leading, horizontalSpacing: Style.cardGridColumnSpacing, verticalSpacing: Style.cardReadingRowSpacing) {
                GridRow(alignment: .firstTextBaseline) {
                    label(Wording.readHeading)
                    VStack(alignment: .leading, spacing: Style.readingLineSpacing) {
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
        HStack(spacing: Style.actionSpacing) {
            Button(Wording.open) { model.open(d.path) }
            Button(Wording.showInFinder) { model.reveal(d.path) }
            Button(Wording.howWasThisRead) { showingTrace = true }
            Spacer()
            switch d.status {
            case .filed:
                Button(Wording.undoFiling) { run(Wording.undoAction) { try await $0.review.undo(documentID) } }
                    .help(Wording.undoFilingHelp)
                Button(Wording.looksRight) { run(Wording.confirmAction) { try await $0.review.confirm(documentID) } }
                    .help(Wording.confirmFiledHelp)
            case .needsReview, .failed:
                Button(Wording.leaveForLater) { run(Wording.holdAction) { try await $0.review.hold(documentID) } }
                Button(Wording.readAgain) { run(Wording.readAgainAction) { try await $0.review.retry(documentID) } }
                Button(Wording.looksRight) { run(Wording.confirmAction) { try await $0.review.confirm(documentID) } }
                    .help(Wording.confirmWaitingHelp)
            case .held, .undone:
                Button(Wording.readAgain) { run(Wording.readAgainAction) { try await $0.review.retry(documentID) } }
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
        run(Wording.changeLabelsAction) { try await $0.review.edit(documentID, fileName: nil, labels: labels) }
    }

    /// Renames the file when the user leaves the name, as Things saves a field; an unchanged name is left alone.
    private func rename() async {
        guard let d = document else { return }
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != (d.filename as NSString).deletingPathExtension else { return }
        await model.perform(Wording.renameAction) { try await $0.review.edit(documentID, fileName: value, labels: nil) }
    }

    private func run(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> Void) {
        Task { await model.perform(what, action) }
    }

    private func close() {
        withAnimation(.snappy) { onClose() }
    }

    private func load() async {
        document = await model.load(Wording.loadDocumentAction) { try await $0.services.documents.document(id: documentID) } ?? nil
        guard let document, !editingName else { return }
        name = (document.filename as NSString).deletingPathExtension
    }
}

/// One label on a card; under the pointer, a × takes it off the document. Its menu opens it among the archive's labels,
/// or removes it from every document for good.
struct LabelChip: View {
    @Environment(AppModel.self) private var model
    let label: DocumentLabel
    let remove: () -> Void
    @State private var hovering = false
    @State private var confirmingRemoval = false

    var body: some View {
        HStack(spacing: Style.chipContentSpacing) {
            Text(Wording.label(label)).textSelection(.enabled)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(Wording.removeLabelHelp)
            }
        }
        .padding(Style.labelChipInsets)
        .background(Style.hover, in: .capsule)
        .onHover { hovering = $0 }
        .contextMenu {
            if model.runtime?.config.labels.vocabulary.kinds[label.kind] != nil {
                Button(Wording.showInLabels) { model.open(label: label) }
            }
            Button(Wording.showDocuments) { model.browse(label) }
            Divider()
            Button(Wording.removeFromEveryDocument) { confirmingRemoval = true }
        }
        .confirmationDialog(Wording.removeEverywhereQuestion(Wording.label(label)), isPresented: $confirmingRemoval) {
            Button(Wording.removeEverywhere, role: .destructive) {
                let label = label
                Task { await model.perform(Wording.removeLabelAction) { try await $0.labels.ignore(label) } }
            }
        } message: {
            Text(Wording.removedForGoodFromCard)
        }
    }
}
