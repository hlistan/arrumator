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

/// A document opened in place: what the model read it as and its labels, what the app learned from it, and every way
/// to correct it. Each change goes through `ReviewActions`, which records it; a corrected sender is learned from.
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
    @State private var showingTrace = false
    @FocusState private var focus: Field?

    private enum Field { case name, correspondent, date }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let document {
                header(document)
                fields(document)
                reading(document)
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
                    .disabled(d.analysis == nil)
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
        .disabled(d.analysis == nil)
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

    private var learned: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow(alignment: .firstTextBaseline) {
                label("Learned")
                VStack(alignment: .leading, spacing: 0) {
                    if lessons.isEmpty {
                        Text("Nothing yet. Correcting its sender teaches Arrumator another name for it.")
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
            Button("How Was This Read?") { showingTrace = true }
            Spacer()
            switch d.status {
            case .filed:
                Button("Undo Filing") { run("Undo") { try await $0.review.undo(documentID) } }
                    .help("Move it back to Incoming and forget what it taught about its sender")
                Button("Looks Right") { run("Confirm") { try await $0.review.confirm(documentID) } }
                    .help("Confirm its name, details and labels")
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

    private func typeBinding(_ d: DocumentRecord) -> Binding<DocumentType> {
        Binding(get: { d.analysis?.documentType ?? .other }, set: { type in
            run("Change type") { try await $0.review.edit(documentID, fileName: nil, title: nil, correspondent: nil, date: nil, type: type) }
        })
    }

    /// Saves a field when the user leaves it, as Things does; unchanged fields are left alone.
    private func commit(_ field: Field) async {
        guard let d = document, let analysis = d.analysis else { return }
        switch field {
        case .name:
            let value = name.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != (d.filename as NSString).deletingPathExtension else { return }
            await model.perform("Rename") { try await $0.review.edit(documentID, fileName: value, title: nil, correspondent: nil,
                                                                     date: nil, type: nil) }
        case .correspondent:
            let value = correspondent.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != (analysis.correspondent ?? "") else { return }
            await model.perform("Change correspondent") { try await $0.review.edit(documentID, fileName: nil, title: nil,
                                                                                   correspondent: value, date: nil, type: nil) }
        case .date:
            let value = date.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != (analysis.documentDate ?? "") else { return }
            await model.perform("Change date") { try await $0.review.edit(documentID, fileName: nil, title: nil,
                                                                          correspondent: nil, date: value, type: nil) }
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
        correspondent = document.analysis?.correspondent ?? document.correspondent ?? ""
        date = document.analysis?.documentDate ?? document.docDate ?? ""
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
        return await model.load("Check what is still known") { try await $0.senders.known(facts) } ?? []
    }
}
