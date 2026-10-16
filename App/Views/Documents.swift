import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// Documents the way Things lists to-dos: one line each, what happened to it at the end, its labels beneath, and a
/// click opens the document in place as a card. While documents are added to a search task, each row ends with a button
/// that adds it to the task's set or takes it out.
///
/// Each row can be moved to the Trash (`ReviewActions.remove`) from its context menu, as an accessibility action and with
/// the shortcut (`Style.moveToTrashShortcut`) while it has keyboard focus, asking as the card does; one Core would refuse
/// (`ListedDocument.removalRefusal`) is dimmed in the menu with why, and the action and the shortcut say why instead of
/// asking. Focus then goes to the row that takes its place.
///
/// A page that holds its rows as one focus stop, with a highlight its arrow keys move (`SearchPage`), shares the focus its
/// rows take of their own, with Keyboard navigation on, between its lists (`rowFocus`), as `SidebarLabelList` does: the
/// highlight shows only while no row has the focus, whose ring shows where the keyboard is, and the arrow keys then move
/// that focus. VoiceOver's cursor moves with the keyboard.
struct DocumentList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let documents: [ListedDocument]
    /// Every document of the page in the order it shows them, across the lists it has, so the row after a removed one is
    /// the page's next, not only this list's.
    let pageOrder: [Int64]
    /// The text around what a search found of each document, by its number, under its row, as it is shown; none where a list is
    /// no search's.
    let snippets: [Int64: AttributedString]
    /// The focus the rows of the page's lists take, shared by them, as a page that holds its rows as one focus stop has it
    /// (`SearchPage`): the keyboard is sent to a row through `AppModel.session.rowToFocus` to the page, which moves its
    /// highlight there. None: this list's rows take the keyboard's focus of their own when it is sent to them, as a page of
    /// rows does.
    private let sharedFocus: FocusState<Int64?>.Binding?
    /// The row the page's arrow keys are on, while they move one; none otherwise.
    let keyed: Int64?
    /// Whether the page's container has the keyboard, so its highlight shows on `keyed`.
    let highlighting: Bool
    /// The document whose removal is being asked about.
    @State private var confirming: Int64?
    @FocusState private var ownFocus: Int64?
    /// The row VoiceOver's cursor is on, moved with the page's arrow keys.
    @AccessibilityFocusState private var spoken: Int64?

    init(documents: [ListedDocument], pageOrder: [Int64]? = nil, snippets: [Int64: AttributedString] = [:],
         rowFocus: FocusState<Int64?>.Binding? = nil, keyed: Int64? = nil, highlighting: Bool = false) {
        self.documents = documents
        self.pageOrder = pageOrder ?? documents.compactMap(\.id)
        self.snippets = snippets
        self.sharedFocus = rowFocus
        self.keyed = keyed
        self.highlighting = highlighting
    }

    private var focus: FocusState<Int64?>.Binding { sharedFocus ?? $ownFocus }

    /// Whether the page, not this list, takes the keyboard when it is sent to a row.
    private var heldByPage: Bool { sharedFocus != nil }

    var body: some View {
        Group {
            ForEach(documents) { listed in
                if let id = listed.id, model.session.openDocument == id {
                    DocumentCard(documentID: id) {
                        guard model.session.openDocument == id else { return }
                        model.session.openDocument = nil
                        // Escape returns the keyboard to the row the card opened from.
                        model.session.rowToFocus = id
                    }
                } else {
                    HStack(spacing: Style.rowAccessorySpacing) {
                        ListRow(symbol: listed.record.status.symbol, tint: listed.record.status.tint, title: listed.record.filename,
                                detail: listed.detail, subtitle: listed.labels,
                                excerpt: listed.id.flatMap { snippets[$0] })
                            .rowAction { withAnimation(.snappy) { model.session.openDocument = listed.id } }
                            .focused(focus, equals: listed.id)
                            .accessibilityFocused($spoken, equals: listed.id)
                            .accessibilityAction(named: Wording.moveToTrashEllipsis) { ask(listed) }
                            .onKeyPress(Style.deleteKeyPress, phases: .down) { press in
                                // Caps Lock is the keyboard's state, not a key pressed with the chord, as the menu's shortcut takes it.
                                guard press.modifiers.subtracting(.capsLock) == Style.moveToTrashShortcut.modifiers else { return .ignored }
                                ask(listed)
                                return .handled
                            }
                            .contextMenu {
                                Button(Wording.moveToTrashEllipsis) { ask(listed) }
                                    .keyboardShortcut(Style.moveToTrashShortcut)
                                    .disabled(listed.removalRefusal != nil)
                                    .help(listed.removalRefusal.map(Wording.reason) ?? Wording.moveToTrashHelp)
                            }
                        if let task = model.session.collecting, let id = listed.id {
                            CollectToggle(task: task, document: id, name: listed.record.filename)
                        }
                    }
                    .background(highlighted(listed) ? Style.sidebarLabelKeyed : .clear, in: .rect(cornerRadius: Style.rowCornerRadius))
                    .id(listed.id)
                    .confirmsMoveToTrash(isPresented: Binding(get: { confirming == listed.id }, set: { if !$0 { confirming = nil } }),
                                         name: listed.record.filename) { moveToTrash(listed) }
                }
            }
        }
        // The removal a page that holds its rows as one stop asked for by the keyboard, for a row of this list.
        .onChange(of: removalAskedOfThisList, initial: true) { _, id in
            guard let id, let listed = documents.first(where: { $0.id == id }) else { return }
            model.session.removeRequested = nil
            ask(listed)
        }
        // The row the keyboard is sent to, once this list holds it: also when this list was made in the very update that named
        // the row, as when a section appears as a card closes, and when the list grows to hold it. A page change clears it
        // (`AppModel.go`), so a row named earlier is never taken up later.
        .onChange(of: rowToFocusHere, initial: true) { _, next in
            guard let next else { return }
            focus.wrappedValue = next
            model.session.rowToFocus = nil
        }
        // VoiceOver's cursor goes where the page's arrow keys go, as the sidebar's does.
        .onChange(of: keyed) { _, row in
            if voiceOver { spoken = row.flatMap { row in documents.contains { $0.id == row } ? row : nil } }
        }
    }

    /// The row of this list the keyboard was sent to, where its rows take the focus of their own: not one whose card is open,
    /// which is in its place and takes the keyboard when it closes.
    private var rowToFocusHere: Int64? {
        guard !heldByPage, let row = model.session.rowToFocus, row != model.session.openDocument else { return nil }
        return documents.contains { $0.id == row } ? row : nil
    }

    /// Whether the page's highlight is on the row: only while the container has the keyboard, not a row of it, whose own focus
    /// ring shows where the keyboard is.
    private func highlighted(_ listed: ListedDocument) -> Bool {
        highlighting && sharedFocus?.wrappedValue == nil && keyed == listed.id
    }

    /// The document of this list the page's keyboard asked to move to the Trash, if it is one.
    private var removalAskedOfThisList: Int64? {
        model.session.removeRequested.flatMap { id in documents.contains { $0.id == id } ? id : nil }
    }

    /// Asks whether to move the document to the Trash; when Core would refuse, says why instead, to the eye and to
    /// VoiceOver, so nothing pressed is met with nothing.
    private func ask(_ listed: ListedDocument) {
        guard let refusal = listed.removalRefusal else {
            confirming = listed.id
            return
        }
        model.refuseMoveToTrash(listed.record.filename, because: refusal)
        AccessibilityNotification.Announcement(Wording.reason(refusal)).post()
    }

    /// Sends the keyboard to the row of document `id`: its focus when this list holds it, or when the page shares the focus of
    /// its rows between its lists and a row had it (`ringed`); else the page, which a list of another section, or a page that
    /// holds its rows as one focus stop, takes up when it reads `rowToFocus`; nowhere once none is left.
    private func send(keyboardTo id: Int64?, ringed: Bool) {
        if let id, heldByPage ? ringed : documents.contains(where: { $0.id == id }) {
            focus.wrappedValue = id
        } else {
            focus.wrappedValue = nil
            model.session.rowToFocus = id
        }
    }

    /// The row that takes the place of document `id` on the page when it leaves: the next, else the previous, else none.
    private func replacement(for id: Int64) -> Int64? {
        guard let at = pageOrder.firstIndex(of: id) else { return nil }
        if pageOrder.indices.contains(at + 1) { return pageOrder[at + 1] }
        return at > 0 ? pageOrder[at - 1] : nil
    }

    private func moveToTrash(_ listed: ListedDocument) {
        guard let id = listed.id else { return }
        let neighbour = replacement(for: id)
        let ringed = focus.wrappedValue != nil
        Task<Void, Never> {
            guard await model.moveToTrash(id, name: listed.record.filename) else { return }
            // To the row that takes its place, or to the page when none is left; a row of another list takes it when it reads.
            send(keyboardTo: neighbour, ringed: ringed)
        }
    }
}

extension View {
    /// The question the card and a document's row ask before a document is moved to the Trash: one dialog for both,
    /// with Move to Trash and Cancel, which leaves everything as it was.
    func confirmsMoveToTrash(isPresented: Binding<Bool>, name: String, perform: @escaping () -> Void) -> some View {
        confirmationDialog(Wording.moveToTrashQuestion(name), isPresented: isPresented) {
            Button(Wording.moveToTrash, role: .destructive, action: perform)
        } message: {
            Text(Wording.movedToTrashMessage)
        }
    }
}

/// Says a document was moved to the Trash, with a way to put it back (`ReviewActions.putBack`), on the page it was moved
/// from, until another page is shown or another document is moved.
struct RemovedNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let removed = model.session.removed {
            Notice(text: Wording.movedToTrashNotice(removed.name), action: (Wording.putBack, { Task<Void, Never> { await model.putBack(document: removed.id) } }),
                   actionName: Wording.putBackNamed(removed.name))
        }
    }
}

/// Documents under headings (`DocumentSection`): what was processed under the day it was processed, the latest first
/// (Processed, and what was just processed on Incoming, read the same way), and the documents the sidebar's labels choose
/// under the month of their own date, the newest first and those without a date last.
struct DocumentSections: View {
    @Environment(AppModel.self) private var model
    let sections: [DocumentSection]

    var body: some View {
        ForEach(sections) { section in
            // Built at once while it holds the open card, of any height (`PageSection`).
            PageSection(section.title, lazily: !section.documents.contains { $0.id == model.session.openDocument }) {
                DocumentList(documents: section.documents, pageOrder: sections.flatMap { $0.documents.compactMap(\.id) })
            }
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
    @State private var showingText = false
    /// What the card offers, as Core decides it from where the document is (`ReviewActions.choices`).
    @State private var choices = DocumentChoices(actions: [], notFiled: false)
    /// The labels the archive has of the kind being added, the most used first, tags the user added among them
    /// (`LabelStore.listing()`), and those of them offered, the most alike to what is typed first, worked out as the kind
    /// or the text changes, never as the card is drawn.
    @State private var inUse: [String] = []
    @State private var offered: [String] = []
    @State private var confirmingTrash = false
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
        // The first Escape in the name field puts back the saved name (`nameField`); a second closes the card.
        .onExitCommand { if !editingName { close() } }
        .task(id: model.ingestActivity) { await load() }
        .onChange(of: editingName) { wasEditing, _ in
            if wasEditing { Task { await rename() } }
        }
        .sheet(isPresented: $showingTrace) {
            TraceView(documentID: documentID, name: document?.filename).environment(model).frame(minWidth: Style.traceSheetMinimum.width, minHeight: Style.traceSheetMinimum.height)
        }
        .sheet(isPresented: $showingText) {
            RecognisedTextView(documentID: documentID, name: document?.filename).environment(model)
                .frame(minWidth: Style.textSheetMinimum.width, minHeight: Style.textSheetMinimum.height)
        }
    }

    // MARK: Parts

    private func header(_ d: DocumentRecord) -> some View {
        HStack(alignment: .top, spacing: Style.thumbnailSpacing) {
            FileThumbnail(url: d.url, size: Style.thumbnail)
                .openAction { model.open(d.path) }
                .accessibilityLabel(Wording.openNamed(d.filename))
                .help(Wording.doubleClickToOpen)
            VStack(alignment: .leading, spacing: Style.cardHeaderSpacing) {
                TextField(Wording.name, text: $name)
                    .font(.title3.weight(.semibold))
                    .nameField(editing: editingName, name: $name, saved: (d.filename as NSString).deletingPathExtension) { leaveName() }
                    .accessibilityLabel(Wording.name)
                    .focused($editingName)
                    .onSubmit { leaveName() }
                placement(d)
                Text(Wording.arrived(as: d.originalFilename, at: d.addedAt))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { close() } label: { Image(systemName: "xmark").frame(minWidth: Style.minimumHit.width, minHeight: Style.minimumHit.height) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(Wording.close)
                .contentShape(.rect)
                .accessibilityLabel(Wording.closeNamed(d.filename))
        }
    }

    /// Where it is, or what happened to it, and when the user confirmed it as it is, if they did (`DocumentChoices`).
    private func placement(_ d: DocumentRecord) -> some View {
        HStack(spacing: Style.placementSpacing) {
            Image(systemName: d.status.symbol).foregroundStyle(d.status.tint)
            Text(Wording.placement(of: d, archive: model.archive, incoming: model.settings?.incomingURL))
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
                            .frame(minWidth: Style.cardLabelFieldMinWidth)
                            .onSubmit { add() }
                        if !offered.isEmpty {
                            Menu {
                                ForEach(offered, id: \.self) { value in Button(value) { newValue = value } }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(Wording.chooseLabelToAdd)
                            .accessibilityLabel(Wording.chooseLabelToAdd)
                        }
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
                .task(id: [newKind.rawValue, model.activity.description]) { await loadInUse() }
                .task(id: [newValue] + inUse) {
                    guard let limit = model.runtime?.config.labels.vocabulary.suggestionLimit else { return }
                    let typed = newValue.trimmingCharacters(in: .whitespaces)
                    offered = typed.isEmpty ? Array(inUse.prefix(limit)) : LabelSimilarity.mostAlike(to: typed, among: inUse, limit: limit)
                }
            }
        }
    }

    /// The label being written, its kind and its value; nil while the field is blank.
    private var typedLabel: DocumentLabel? {
        let value = newValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : DocumentLabel(kind: newKind, value: value)
    }

    /// What the model read the document as, who read it, and anything that keeps it waiting for the user.
    @ViewBuilder private func reading(_ d: DocumentRecord) -> some View {
        if let analysis = d.analysis {
            Grid(alignment: .leading, horizontalSpacing: Style.cardGridColumnSpacing, verticalSpacing: Style.cardReadingRowSpacing) {
                if let interpretation = analysis.interpretation {
                    GridRow(alignment: .firstTextBaseline) {
                        label(Wording.interpretationHeading)
                        Text(interpretation).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
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

    /// The card's buttons, on as many rows as the width needs, none wrapping its title (`ActionRow`): what it does with the
    /// file first, then what it does with the document, which stand at the right edge of their row.
    private func actions(_ d: DocumentRecord) -> some View {
        ActionRow(spacing: Style.actionSpacing, rowSpacing: Style.actionRowSpacing) {
            Button(Wording.open) { model.open(d.path) }
            Button(Wording.showInFinder) { model.reveal(d.path) }
            Button(Wording.recognisedText) { showingText = true }
                .disabled(choices.nothingToShow != nil)
                .help(choices.nothingToShow.map(Wording.nothingToShow) ?? Wording.recognisedTextHelp)
            Button(Wording.howWasThisRead) { showingTrace = true }
            ForEach(Array(choices.actions.enumerated()), id: \.element) { place, action in
                actionButton(action, of: d)
                    .startsTrailingGroup(place == 0)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    @ViewBuilder private func actionButton(_ action: DocumentAction, of d: DocumentRecord) -> some View {
        switch action {
        case .undo:
            Button(Wording.undoFiling) { run(Wording.undoAction) { try await $0.review.undo(documentID) } }
                .help(Wording.undoFilingHelp)
        case .confirm:
            Button(d.status == .filed ? Wording.looksRight : Wording.keepAsItIs) { run(Wording.confirmAction) { try await $0.review.confirm(documentID) } }
                .help(d.status == .filed ? Wording.confirmFiledHelp : Wording.confirmWaitingHelp)
        case .hold:
            Button(Wording.leaveForLater) { run(Wording.holdAction) { try await $0.review.hold(documentID) } }
        case .readAgain:
            readAgain
        case .remove:
            Button(Wording.moveToTrashEllipsis) { confirmingTrash = true }
                .help(Wording.moveToTrashHelp)
                .confirmsMoveToTrash(isPresented: $confirmingTrash, name: d.filename) { moveToTrash(d.filename) }
        }
    }

    /// Moves the document's file to the Trash and takes it out of the archive (`ReviewActions.remove`); the card closes
    /// once it has, as the document is no more.
    private func moveToTrash(_ name: String) {
        Task<Void, Never> {
            guard await model.moveToTrash(documentID, name: name) else { return }
            close()
        }
    }

    /// Read Again; dimmed, with why as its help and for VoiceOver, where reading again cannot help (`ReviewActions.readAgainRefusal`);
    /// and, while Core says a reading of the document is queued or under way, that it waits to be read again.
    @ViewBuilder private var readAgain: some View {
        if choices.readingQueued {
            Text(Wording.readAgainQueued).foregroundStyle(.secondary)
        } else {
            let refusal = choices.readAgainRefusal.map(Wording.reason)
            Button(Wording.readAgain) {
                let name = Wording.documentName(document, id: documentID)
                Task<Void, Never> {
                    // Also said by a page the document leaves, with this card, as Needs You (`ArchiveSession.readAgain`).
                    if await model.perform(Wording.readAgainAction, { try await $0.review.retry(documentID) }) != nil {
                        model.session.readAgain = (documentID, name)
                    }
                }
            }
            .disabled(refusal != nil)
            .help(refusal ?? Wording.readAgainHelp)
            .accessibilityHint(refusal ?? "")
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

    /// The name's field gives up the keyboard, which goes to the card's row: a page that holds its rows as one stop takes it
    /// there, so a second Escape still reaches the card (`SearchPage`); a page of rows that take focus has none here, for the
    /// card is in the row's place.
    private func leaveName() {
        editingName = false
        model.session.rowToFocus = documentID
    }

    /// The labels the archive has of the kind being added, of the kinds written freely; none of a kind with one form. A
    /// load cut short, as by what the app is doing changing while it read, leaves those offered as they were
    /// (`AppModel.load`).
    private func loadInUse() async {
        let kind = newKind
        guard model.runtime?.config.labels.isWrittenFreely(kind) == true else {
            inUse = []
            return
        }
        guard let listing = await model.load(Wording.loadLabelsAction, { try await $0.services.labels.listing() }) else { return }
        inUse = (listing[kind] ?? []).map(\.label.value)
    }

    private func load() async {
        guard let read = await model.load(Wording.loadDocumentAction, { try await $0.services.documents.document(id: documentID) }) else { return }
        document = read
        if let document, let offered = await model.load(Wording.loadDocumentAction, { try await $0.review.choices(for: document) }) {
            choices = offered
        }
        guard let document, !editingName else { return }
        name = (document.filename as NSString).deletingPathExtension
    }
}

/// One label on a card; under the pointer, a × takes it off the document. Its menu opens it among the archive's labels,
/// or takes it off every document, once or for good.
struct LabelChip: View {
    @Environment(AppModel.self) private var model
    let label: DocumentLabel
    let remove: () -> Void
    @State private var hovering = false
    @State private var confirmingRemoval = false
    @State private var confirmingRemovalForGood = false

    var body: some View {
        HStack(spacing: Style.chipContentSpacing) {
            // Not selectable: a selectable text has the system's text menu, which comes before the chip's own.
            Text(Wording.label(label))
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").accessibilityLabel(Wording.removeLabelNamed(Wording.label(label)))
                        .frame(minWidth: Style.minimumHit.width, minHeight: Style.minimumHit.height)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(Wording.removeLabelHelp)
                .contentShape(.rect)
            }
        }
        .padding(Style.labelChipInsets)
        .background(Style.hover, in: .capsule)
        .onHover { hovering = $0 }
        // The × shows only under the pointer; the keyboard and VoiceOver reach the same through an action and the menu.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Wording.label(label))
        .accessibilityAction(named: Wording.removeFromDocument, remove)
        .contextMenu {
            Button(Wording.removeFromDocument, action: remove)
            if model.runtime?.config.labels.isWrittenFreely(label.kind) == true {
                Button(Wording.showInLabels) { model.open(label: label) }
            }
            Button(Wording.showDocuments) { model.browse(label) }
            Button(Wording.copyLabel) { model.copy(Wording.label(label)) }
            Divider()
            Button(Wording.removeFromEveryDocument) { confirmingRemoval = true }
            Button(Wording.removeForGoodEllipsis) { confirmingRemovalForGood = true }
        }
        .confirmationDialog(Wording.removeEverywhereQuestion(Wording.label(label)), isPresented: $confirmingRemoval) {
            Button(Wording.remove, role: .destructive) { everywhere { try await $0.labels.remove($1) } }
        } message: {
            Text(Wording.removedMayComeBack)
        }
        .confirmationDialog(Wording.removeForGoodQuestion(Wording.label(label)), isPresented: $confirmingRemovalForGood) {
            Button(Wording.removeForGood, role: .destructive) { everywhere { try await $0.labels.ignore($1) } }
        } message: {
            Text(Wording.removedForGoodFromCard)
        }
    }

    /// Does `action` to the label on every document.
    private func everywhere(_ action: @escaping @Sendable (ArrumatorRuntime, DocumentLabel) async throws -> LabelActionOutcome) {
        let label = label
        Task<Void, Never> { await model.perform(Wording.removeLabelAction) { try await action($0, label) } }
    }
}
