import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// What a document row says at its end.
enum RowDetail {
    /// Where it went, or what happened to it, and who decided.
    case decision
    /// Its date and correspondent, for lists that are already about one folder.
    case document
}

/// Documents the way Things lists to-dos: one line each, the decision at the end, and a click opens the document in
/// place as a card.
struct DocumentList: View {
    @Environment(AppModel.self) private var model
    let documents: [DocumentRecord]
    var detail: RowDetail = .decision
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
        let subtitle = d.id.flatMap { snippets[$0] }?.replacingOccurrences(of: "\n", with: " ")
        return switch detail {
        case .decision:
            ListRow(symbol: d.status.symbol, tint: d.status.tint, title: d.filename,
                    detail: Wording.outcome(of: d, in: model.taxonomy, incoming: model.settings?.incomingURL),
                    tag: d.status == .filed ? Wording.deciderTag(d.decision) : nil, subtitle: subtitle)
        case .document:
            ListRow(symbol: d.status.symbol, tint: d.status.tint, title: d.filename,
                    detail: [d.correspondent, d.docDate].compactMap { $0 }.joined(separator: " · "), subtitle: subtitle)
        }
    }
}

/// A document opened in place: what was decided and why, what the app learned from it, and every way to change the
/// decision. Each change goes through `ReviewActions`, which records it as a correction the app learns from.
struct DocumentCard: View {
    @Environment(AppModel.self) private var model
    let documentID: Int64
    @State private var document: DocumentRecord?
    @State private var lessons: [EventRecord] = []
    /// What the lessons refer to that the app still knows, and can still forget.
    @State private var known: Set<LearnedFact> = []
    @State private var name = ""
    @State private var correspondent = ""
    @State private var date = ""
    @State private var choosingFolder = false
    @State private var showingTrace = false
    @FocusState private var focus: Field?

    private enum Field { case name, correspondent, date }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let document {
                header(document)
                fields(document)
                why(document)
                learned
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
        .onChange(of: focus) { previous, _ in
            if let previous { Task { await commit(previous) } }
        }
        .sheet(isPresented: $choosingFolder) {
            FolderChooser(title: document?.status == .filed ? "Move to" : "File into") { choice in
                choosingFolder = false
                guard let choice else { return }
                Task { await file(into: choice) }
            }
            .environment(model)
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
                    .focused($focus, equals: .name)
                    .onSubmit { focus = nil }
                    .disabled(d.decision == nil)
                placement(d)
                Text("Arrived as \(d.originalFilename) · \(d.addedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Close")
        }
    }

    /// Where it is, or where the app suggests it goes, with the way to change that.
    @ViewBuilder private func placement(_ d: DocumentRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: d.status.symbol).foregroundStyle(d.status.tint)
            switch d.status {
            case .filed:
                Text(Wording.outcome(of: d, in: model.taxonomy, incoming: model.settings?.incomingURL))
                Button("Move…") { choosingFolder = true }.buttonStyle(.link)
            case .needsReview, .held, .undone, .failed:
                Text(Wording.outcome(of: d, in: model.taxonomy, incoming: model.settings?.incomingURL))
                if let target = Wording.target(of: d.decision, in: model.taxonomy) {
                    Button(d.status == .needsReview ? "File There" : "File in \(target)") {
                        run("File") { try await $0.review.approve(documentID) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button("Choose Folder…") { choosingFolder = true }.buttonStyle(.link)
            default:
                Text(Wording.outcome(of: d, in: model.taxonomy, incoming: model.settings?.incomingURL))
            }
        }
        .font(.callout)
    }

    private func fields(_ d: DocumentRecord) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                label("From")
                TextField("Correspondent", text: $correspondent)
                    .textFieldStyle(.plain).focused($focus, equals: .correspondent).onSubmit { focus = nil }
            }
            GridRow {
                label("Date")
                TextField("YYYY-MM-DD", text: $date)
                    .textFieldStyle(.plain).focused($focus, equals: .date).onSubmit { focus = nil }
            }
            GridRow {
                label("Type")
                Picker("Type", selection: typeBinding(d)) {
                    ForEach(DocumentType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            labels(d)
        }
        .disabled(d.decision == nil)
    }

    /// What the model found the document concerns, one row per kind of label it has.
    @ViewBuilder private func labels(_ d: DocumentRecord) -> some View {
        let labels = d.labels ?? []
        ForEach(LabelKind.allCases.filter { kind in labels.contains { $0.kind == kind } }, id: \.self) { kind in
            GridRow(alignment: .firstTextBaseline) {
                label(Wording.labelKind(kind))
                Text(labels.filter { $0.kind == kind }.map(Wording.label).joined(separator: " · "))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func why(_ d: DocumentRecord) -> some View {
        if let decision = d.decision {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow(alignment: .firstTextBaseline) {
                    label("Why")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Wording.decider(decision))
                        if !decision.rationale.isEmpty {
                            Text(decision.rationale).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(decision.reviewReasons, id: \.self) { reason in
                            Text(reason).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    private var learned: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow(alignment: .firstTextBaseline) {
                label("Learned")
                VStack(alignment: .leading, spacing: 0) {
                    if lessons.isEmpty {
                        Text("Nothing yet. Moving, renaming or confirming this document teaches Arrumator.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lessons) { event in LessonRow(event: event, known: known) }
                }
            }
        }
    }

    private func actions(_ d: DocumentRecord) -> some View {
        HStack(spacing: 14) {
            Button("Open") { model.open(d.path) }
            Button("Show in Finder") { model.reveal(d.path) }
            Button("How Was This Decided?") { showingTrace = true }
            Spacer()
            switch d.status {
            case .filed:
                Button("Undo Filing") { run("Undo") { try await $0.review.undo(documentID) } }
                    .help("Move it back to Incoming and forget what was learned from it")
                Button("Looks Right") { run("Confirm") { try await $0.review.markCorrect(documentID) } }
                    .help("Confirm the folder and name, so similar documents are filed the same way")
            case .needsReview, .failed, .undone:
                Button("Leave for Later") { run("Hold") { try await $0.review.hold(documentID) } }
                Button("Decide Again") { run("Retry") { try await $0.review.refile(documentID) } }
            case .held:
                Button("Decide Again") { run("Retry") { try await $0.review.refile(documentID) } }
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

    private func typeBinding(_ d: DocumentRecord) -> Binding<DocumentType> {
        Binding(get: { d.decision?.documentType ?? .other }, set: { type in
            run("Change type") { try await $0.review.edit(documentID, fileName: nil, title: nil, correspondent: nil, date: nil, type: type) }
        })
    }

    /// Saves a field when the user leaves it, as Things does; unchanged fields are left alone.
    private func commit(_ field: Field) async {
        guard let d = document, let decision = d.decision else { return }
        switch field {
        case .name:
            let value = name.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != (d.filename as NSString).deletingPathExtension else { return }
            await model.perform("Rename") { try await $0.review.edit(documentID, fileName: value, title: nil, correspondent: nil,
                                                                     date: nil, type: nil) }
        case .correspondent:
            let value = correspondent.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != (decision.correspondent ?? "") else { return }
            await model.perform("Change correspondent") { try await $0.review.edit(documentID, fileName: nil, title: nil,
                                                                                   correspondent: value, date: nil, type: nil) }
        case .date:
            let value = date.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != (decision.documentDate ?? "") else { return }
            await model.perform("Change date") { try await $0.review.edit(documentID, fileName: nil, title: nil,
                                                                          correspondent: nil, date: value, type: nil) }
        }
    }

    private func file(into choice: FolderChoice) async {
        switch choice {
        case let .existing(folderID):
            await model.perform("Move") { try await $0.review.move(documentID, toFolder: folderID) }
        case let .new(spec):
            await model.perform("Create folder") { try await $0.review.createFolderAndFile(documentID, spec: spec) }
        }
    }

    private func run(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> Void) {
        Task { await model.perform(what, action) }
    }

    private func close() {
        withAnimation(.snappy) { if model.openDocument == documentID { model.openDocument = nil } }
    }

    private func load() async {
        document = await model.load("Load document") { try await $0.services.documents.document(id: documentID) } ?? nil
        lessons = await model.load("Load what was learned") {
            try await $0.services.history.events(limit: $0.config.interface.pageSize, kinds: Wording.lessonKinds, docID: documentID)
        } ?? []
        known = await LessonRow.known(lessons, model: model)
        guard let document, focus == nil else { return }
        name = (document.filename as NSString).deletingPathExtension
        correspondent = document.decision?.correspondent ?? document.correspondent ?? ""
        date = document.decision?.documentDate ?? document.docDate ?? ""
    }
}

/// One thing the app learned. While it still knows it, "Forget" appears under the pointer; once forgotten, the lesson
/// is struck through.
struct LessonRow: View {
    @Environment(AppModel.self) private var model
    let event: EventRecord
    let known: Set<LearnedFact>
    @State private var hovering = false

    private var fact: LearnedFact? { LearnedFact.recorded(by: event) }
    private var forgotten: Bool { fact.map { !known.contains($0) } ?? false }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: EventStyle.symbol(event.kind)).foregroundStyle(EventStyle.color(event.kind)).frame(width: 18)
            Text(Wording.lesson(event))
                .strikethrough(forgotten)
                .foregroundStyle(forgotten ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            if hovering, let fact, !forgotten {
                Button("Forget") { Task { await model.perform("Forget") { try await $0.learner.forget(fact) } } }
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    /// Which of the facts these lessons refer to the app still knows.
    static func known(_ lessons: [EventRecord], model: AppModel) async -> Set<LearnedFact> {
        let facts = lessons.compactMap(LearnedFact.recorded(by:))
        guard !facts.isEmpty else { return [] }
        return await model.load("Check what is still known") { try await $0.learningStore.known(facts) } ?? []
    }
}
