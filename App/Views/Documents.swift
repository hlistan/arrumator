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
                        .rowAction { withAnimation(.snappy) { model.openDocument = document.id } }
                    if let task = model.collecting, let id = document.id {
                        CollectToggle(task: task, document: id)
                    }
                }
            }
        }
    }

    private func row(_ d: DocumentRecord) -> some View {
        ListRow(symbol: d.status.symbol, tint: d.status.tint, title: d.filename,
                detail: Wording.rowDetail(of: d, archive: model.settings?.archiveURL, incoming: model.settings?.incomingURL),
                subtitle: Wording.labels(d.labels))
    }
}

/// Documents under headings, in the order they come, a heading wherever `heading` names another than the one before:
/// what was processed under the day it was processed, the latest first (Processed, and what was just processed on
/// Incoming, read the same way), and the documents the sidebar's labels choose under the month of their own date, the
/// newest first and those without a date last.
struct DocumentSections: View {
    let documents: [DocumentRecord]
    let heading: (DocumentRecord) -> String

    private var sections: [(title: String, documents: [DocumentRecord])] {
        var out: [(title: String, documents: [DocumentRecord])] = []
        for document in documents {
            let title = heading(document)
            if out.last?.title == title { out[out.count - 1].documents.append(document) } else { out.append((title, [document])) }
        }
        return out
    }

    var body: some View {
        ForEach(sections, id: \.title) { section in
            PageSection(section.title) { DocumentList(documents: section.documents) }
        }
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
    /// Read Again was pressed: the card says the document waits to be read, until it is.
    @State private var readAgainAsked = false
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
            TraceView(documentID: documentID, name: document?.filename).environment(model).frame(minWidth: Style.traceSheetMinimum.width, minHeight: Style.traceSheetMinimum.height)
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
                    .padding(.vertical, Style.titleFieldPadding)
                    .accessibilityLabel(Wording.name)
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
                        .accessibilityLabel(Wording.labelPrompt(newKind))
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
                        if [.needsReview, .failed, .held].contains(d.status), let advice = Wording.advice(analysis) {
                            Text(advice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                readAgain
                Button(Wording.looksRight) { run(Wording.confirmAction) { try await $0.review.confirm(documentID) } }
                    .help(Wording.confirmWaitingHelp)
            case .held, .undone:
                readAgain
            default:
                EmptyView()
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    /// Read Again, or, once pressed, that the document waits to be read again.
    @ViewBuilder private var readAgain: some View {
        if readAgainAsked {
            Text(Wording.readAgainQueued).foregroundStyle(.secondary)
        } else {
            Button(Wording.readAgain) {
                Task {
                    readAgainAsked = await model.perform(Wording.readAgainAction) { try await $0.review.retry(documentID) } != nil
                }
            }
        }
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

    /// Renames the file when the user leaves the name, as Things saves a field; an unchanged name is left alone. A blank
    /// one is refused, saying why, and the field shows the name the file keeps.
    private func rename() async {
        guard let d = document else { return }
        let current = (d.filename as NSString).deletingPathExtension
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != current else { return }
        await model.perform(Wording.renameAction) { try await $0.review.edit(documentID, fileName: value, labels: nil) }
        if value.isEmpty { name = current }
    }

    private func run(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> Void) {
        Task { await model.perform(what, action) }
    }

    private func close() {
        withAnimation(.snappy) { onClose() }
    }

    private func load() async {
        let readBefore = document?.updatedAt
        document = await model.load(Wording.loadDocumentAction) { try await $0.services.documents.document(id: documentID) } ?? nil
        // Read again since, or no longer waiting: Read Again is offered again where it applies.
        if document?.updatedAt != readBefore || document.map({ ![.needsReview, .failed, .held, .undone].contains($0.status) }) == true {
            readAgainAsked = false
        }
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
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").accessibilityLabel(Wording.removeLabelNamed(Wording.label(label)))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(Wording.removeLabelHelp)
            }
        }
        .padding(Style.labelChipInsets)
        .background(Style.hover, in: .capsule)
        .onHover { hovering = $0 }
        // The × shows only under the pointer; the keyboard and VoiceOver reach the same through an action and the menu.
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Wording.removeFromDocument, remove)
        .contextMenu {
            Button(Wording.removeFromDocument, action: remove)
            if model.runtime?.config.labels.isWrittenFreely(label.kind) == true {
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
