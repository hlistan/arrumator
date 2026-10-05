import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// Documents the way Things lists to-dos: one line each, what happened to it at the end, its labels beneath, and a
/// click opens the document in place as a card. While documents are added to a search task, each row ends with a button
/// that adds it to the task's set or takes it out.
struct DocumentList: View {
    @Environment(AppModel.self) private var model
    let documents: [ListedDocument]

    var body: some View {
        ForEach(documents) { listed in
            if let id = listed.id, model.session.openDocument == id {
                DocumentCard(documentID: id) { if model.session.openDocument == id { model.session.openDocument = nil } }
            } else {
                HStack(spacing: Style.rowAccessorySpacing) {
                    ListRow(symbol: listed.record.status.symbol, tint: listed.record.status.tint, title: listed.record.filename,
                            detail: listed.detail, subtitle: listed.labels)
                        .rowAction { withAnimation(.snappy) { model.session.openDocument = listed.id } }
                    if let task = model.session.collecting, let id = listed.id {
                        CollectToggle(task: task, document: id, name: listed.record.filename)
                    }
                }
            }
        }
    }
}

/// Documents under headings (`DocumentSection`): what was processed under the day it was processed, the latest first
/// (Processed, and what was just processed on Incoming, read the same way), and the documents the sidebar's labels choose
/// under the month of their own date, the newest first and those without a date last.
struct DocumentSections: View {
    let sections: [DocumentSection]

    var body: some View {
        ForEach(sections) { section in
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
    /// Why the label being written is no label of its kind, as Core says it (`LabelError.refusal(of:)`), worked out as it
    /// is typed rather than as the card is drawn.
    @State private var newLabelRefusal: String?
    @State private var showingTrace = false
    /// Read Again was pressed: the card says the document waits to be read, until it is.
    @State private var readAgainAsked = false
    /// What the card offers, as Core decides it from where the document is (`ReviewActions.choices`).
    @State private var choices = DocumentChoices(actions: [], notFiled: false)
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
                .openAction { model.open(d.path) }
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
                .accessibilityLabel(Wording.closeNamed(d.filename))
        }
    }

    /// Where it is, or what happened to it, and when the user confirmed it as it is, if they did (`DocumentChoices`).
    private func placement(_ d: DocumentRecord) -> some View {
        HStack(spacing: Style.placementSpacing) {
            Image(systemName: d.status.symbol).foregroundStyle(d.status.tint)
            Text(Wording.outcome(of: d, archive: model.archive, incoming: model.settings?.incomingURL))
            if let confirmed = choices.confirmed {
                Text(Wording.labelSeparator + Wording.confirmedByYou(at: confirmed)).foregroundStyle(.secondary)
            }
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
                            LabelChip(label: item) { save(LabelEdit(removing: [item])) }
                        }
                    }
                }
            }
            GridRow(alignment: .firstTextBaseline) {
                label(labels.isEmpty ? Wording.labelsHeading : "")
                VStack(alignment: .leading, spacing: Style.fieldRefusalSpacing) {
                    HStack(spacing: Style.inlineControlSpacing) {
                        Picker(Wording.labelKindPicker, selection: $newKind) {
                            ForEach(LabelKind.allCases, id: \.self) { Text(Wording.labelKind($0)).tag($0) }
                        }
                        .labelsHidden().frame(width: Style.labelKindPickerWidth)
                        // Named for what it is, whatever example of its kind it shows.
                        TextField(Wording.newLabelField(newKind), text: $newValue, prompt: Text(Wording.labelPrompt(newKind)))
                            .accessibilityLabel(Wording.newLabelField(newKind))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { add() }
                        Button(Wording.add) { add() }
                            .disabled(typedLabel == nil || newLabelRefusal != nil)
                    }
                    .controlSize(.small)
                    if let newLabelRefusal {
                        Text(newLabelRefusal).font(.caption).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: typedLabel, initial: true) { _, typed in
                    newLabelRefusal = typed.flatMap(LabelError.refusal(of:))?.localizedDescription
                }
            }
        }
    }

    /// The label being written, its kind and its value; nil while the field is blank.
    private var typedLabel: DocumentLabel? {
        let value = newValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : DocumentLabel(kind: newKind, value: value)
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
                            Text(DocumentAnalysis.said([problem])).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
                        }
                        if [.needsReview, .failed, .held].contains(d.status), let advice = Wording.advice(analysis) {
                            Text(advice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if choices.notFiled {
                            Text(Wording.notFiledAdvice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            ForEach(choices.actions, id: \.self) { action in
                switch action {
                case .undo:
                    Button(Wording.undoFiling) { run(Wording.undoAction) { try await $0.review.undo(documentID) } }
                        .help(Wording.undoFilingHelp)
                case .confirm:
                    Button(Wording.looksRight) { run(Wording.confirmAction) { try await $0.review.confirm(documentID) } }
                        .help(d.status == .filed ? Wording.confirmFiledHelp : Wording.confirmWaitingHelp)
                case .hold:
                    Button(Wording.leaveForLater) { run(Wording.holdAction) { try await $0.review.hold(documentID) } }
                case .readAgain:
                    readAgain
                }
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
                let name = Wording.documentName(document, id: documentID)
                Task<Void, Never> {
                    readAgainAsked = await model.perform(Wording.readAgainAction) { try await $0.review.retry(documentID) } != nil
                    // Also said by a page the document leaves, with this card, as Needs You (`ArchiveSession.readAgain`).
                    if readAgainAsked { model.session.readAgain = (documentID, name) }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    // MARK: Changes

    /// Adds the label being typed; Core decides what it does to the labels the document has then (`LabelEdit`). One that
    /// is no label of its kind stays in the field, under why, to be corrected.
    private func add() {
        guard let typed = typedLabel, LabelError.refusal(of: typed) == nil else { return }
        save(LabelEdit(adding: [typed]))
        newValue = ""
    }

    /// Sends what the user did to the labels, never the set the card last showed, so changes made in quick succession
    /// each keep the others.
    private func save(_ change: LabelEdit) {
        run(Wording.changeLabelsAction) { try await $0.review.edit(documentID, fileName: nil, labels: change) }
    }

    /// Renames the file when the user leaves the name, as Things saves a field; an unchanged name is left alone. A name
    /// the document cannot have (`IngestError.unusableFileName`: a blank one, one cleaning leaves nothing of, one of the
    /// app's own files) or a rename that fails is refused, saying why, and the field shows the name the file keeps.
    private func rename() async {
        guard let d = document else { return }
        let current = (d.filename as NSString).deletingPathExtension
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != current else { return }
        let renamed: Void? = await model.perform(Wording.renameAction) { try await $0.review.edit(documentID, fileName: value, labels: nil) }
        if renamed == nil { name = current }
    }

    private func run(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> Void) {
        Task { await model.perform(what, action) }
    }

    private func close() {
        withAnimation(.snappy) { onClose() }
    }

    private func load() async {
        let readBefore = document?.updatedAt
        guard let read = await model.load(Wording.loadDocumentAction, { try await $0.services.documents.document(id: documentID) }) else { return }
        document = read
        if let document, let offered = await model.load(Wording.loadDocumentAction, { try await $0.review.choices(for: document) }) {
            choices = offered
        }
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
                Task<Void, Never> { await model.perform(Wording.removeLabelAction) { try await $0.labels.ignore(label) } }
            }
        } message: {
            Text(Wording.removedForGoodFromCard)
        }
    }
}
