import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// A task's conversation, on its card: each question with its answer, the answer being written as it grows, and between
/// them each change made to the task's set, so what each answer could draw on shows; then a field to ask the next. An
/// answer lists the documents it draws on, to open, and those it found outside the task when it was asked for more, to
/// add (`TaskConversationActions`, `SearchTaskActions`).
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let task: SearchTask
    @State private var items: [ConversationItem] = []
    /// The documents the answers draw on and found, by number.
    @State private var documents: [Int64: ListedDocument] = [:]
    @State private var question = ""
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: Style.conversationSpacing) {
            if items.isEmpty { Text(Wording.noQuestionsYet).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ForEach(items) { item in
                if let turn = item.turn {
                    TurnView(turn: turn, task: task, documents: documents, answeredAfterLater: answeredAfterLater(turn))
                } else {
                    Label(item.change ?? "", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            composer
        }
        .task(id: model.conversationActivity) { await load() }
        .confirmationDialog(Wording.clearConversationQuestion(task.name), isPresented: $confirmingClear) {
            Button(Wording.clearConversationConfirm, role: .destructive) {
                let id = task.id
                Task<Void, Never> { await model.perform(Wording.clearConversationAction) { try await $0.conversations.clear(id) } }
            }
        } message: {
            Text(Wording.clearConversationNote)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Style.turnSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Style.askSpacing) {
                TextField(Wording.askAboutPrompt, text: $question, axis: .vertical)
                    .accessibilityLabel(Wording.questionField)
                    .lineLimit(1...Style.askMaxLines)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button(Wording.ask, action: ask).disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !items.isEmpty {
                Button(Wording.clearConversation) { confirmingClear = true }
                    .buttonStyle(.borderless).font(.callout)
            }
        }
    }

    /// Asks what was typed. A question that is refused says why and is given back, unless something else has been typed
    /// since.
    private func ask() {
        let typed = question
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        question = ""
        let id = task.id
        Task<Void, Never> {
            if await model.perform(Wording.askQuestionAction, { try await $0.conversations.ask(id, question: typed) }) == nil,
               question.isEmpty {
                question = typed
            }
        }
    }

    /// Whether `turn` was answered, asked again, after a question below it was: that question followed its earlier answer.
    private func answeredAfterLater(_ turn: TaskTurn) -> Bool {
        guard let answered = turn.answered else { return false }
        return items.compactMap(\.turn).contains { $0.id > turn.id && ($0.answered ?? .distantFuture) < answered }
    }

    private func load() async {
        let id = task.id
        guard let loaded = await model.load(Wording.loadConversationAction, { runtime -> ([ConversationItem], [DocumentRecord]) in
            let items = try await runtime.conversations.store.conversation(task: id)
            let named = items.compactMap(\.turn).flatMap { $0.sources + ($0.finding?.documents ?? []) }
            return (items, try await runtime.services.documents.documents(ids: Array(Set(named))))
        }) else { return }
        items = loaded.0
        documents = Dictionary(model.listed(loaded.1).compactMap { d in d.id.map { ($0, d) } }, uniquingKeysWith: { a, _ in a })
    }
}

/// A question and its answer: the question set apart; the answer, or, while the question is in the queue, what the queue
/// does with it and what has come of the answer so far; the documents the answer draws on and those it found; and ways
/// to copy the answer, ask again, or stop.
private struct TurnView: View {
    @Environment(AppModel.self) private var model
    let turn: TaskTurn
    let task: SearchTask
    let documents: [Int64: ListedDocument]
    let answeredAfterLater: Bool

    var body: some View {
        let progress = model.session.conversation.progress(of: turn)
        VStack(alignment: .leading, spacing: Style.turnSpacing) {
            Text(turn.question)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Style.questionInsets)
                .background(Style.hover, in: .rect(cornerRadius: Style.questionCornerRadius))
            if let progress {
                TurnProgressView(progress: progress)
            } else if let answer = turn.answer {
                Answer(text: answer)
                if answeredAfterLater {
                    Label(Wording.answeredAfterLater, systemImage: "arrow.uturn.down")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem = Wording.turnProblem(turn) {
                Text(problem).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
            }
            if !turn.sources.isEmpty { sources }
            if let finding = turn.finding { FindingView(finding: finding, task: task, documents: documents) }
            actions(progress: progress)
        }
    }

    /// The documents the answer draws on, one a line so that each keeps its whole name: a date, a sender and a title.
    private var sources: some View {
        VStack(alignment: .leading, spacing: Style.sourceSpacing) {
            Text(Wording.drawnFrom).foregroundStyle(.secondary)
            ForEach(turn.sources.compactMap { documents[$0] }, id: \.id) { document in
                Button { model.open(document.record.path) } label: {
                    Label(document.record.filename, systemImage: "doc.text").lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .padding(Style.labelChipInsets)
                .background(Style.hover, in: .capsule)
                .help(Wording.openNamedDocument(document.record.filename))
            }
        }
        .font(.callout)
    }

    private func actions(progress: TurnProgress?) -> some View {
        HStack(spacing: Style.actionSpacing) {
            if progress != nil {
                Button(Wording.stopAnswer) {
                    let id = turn.id
                    Task<Void, Never> { await model.perform(Wording.stopAnswerAction) { try await $0.conversations.stop(id) } }
                }
                .help(Wording.stopAnswerHelp)
            } else {
                if let answer = turn.answer {
                    Button(Wording.copyAnswer) { model.copy(answer) }.help(Wording.copyAnswerHelp)
                }
                Button(Wording.askAgain) {
                    let id = turn.id
                    Task<Void, Never> { await model.perform(Wording.askAgainAction) { _ = try await $0.conversations.askAgain(id) } }
                }
                .help(Wording.askAgainHelp)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

/// An answer, its Markdown shown block by block (`AnswerMarkdown`): paragraphs, headings, lists with their markers, quotes
/// and code, each with its emphasis and inline code; a link shows as its words and address, and an image as its words,
/// so nothing in an answer can be clicked.
private struct Answer: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Style.answerBlockSpacing) {
            // Markdown that cannot be read is shown as it was written, which is all it is then.
            if let blocks = AnswerMarkdown.blocks(text) {
                ForEach(blocks) { block($0) }
            } else {
                Text(text)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func block(_ block: AnswerMarkdown.Block) -> some View {
        switch block.kind {
        case let .heading(level):
            Text(block.text).font(level <= Style.answerLargeHeadingLevel ? .title3.bold() : .headline)
        case let .item(marker):
            HStack(alignment: .firstTextBaseline, spacing: Style.answerMarkerSpacing) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: Style.answerMarkerWidth, alignment: .trailing)
                Text(block.text)
            }
            .padding(.leading, CGFloat(block.depth) * Style.answerListIndent)
        case .quote:
            Text(block.text).foregroundStyle(.secondary).padding(.leading, Style.answerListIndent)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: Style.answerQuoteRule) }
        case .code:
            Text(block.text).font(.body.monospaced())
        case .paragraph:
            Text(block.text)
        }
    }
}

/// What the queue does with a question: while it is answered, what has come of the answer so far
/// (`AppModel.answerSoFar`), below a line saying by which model and for how long, or that it thinks; else what it waits
/// for, Ollama marked as a notice.
private struct TurnProgressView: View {
    @Environment(AppModel.self) private var model
    let progress: TurnProgress

    /// What has come of the answer, while this question is the one answered.
    private var written: AnswerProgress? {
        guard case .answering(_?) = progress else { return nil }
        return model.session.answerSoFar
    }

    var body: some View {
        if case .waitingForOllama = progress {
            Notice(text: Wording.turnProgressLine(progress))
        } else {
            VStack(alignment: .leading, spacing: Style.turnSpacing) {
                HStack(spacing: Style.noticeSpacing) {
                    ProgressView().controlSize(.small)
                    if case let .answering(answering?) = progress {
                        TimelineView(.periodic(from: answering.since, by: Style.readingTimeTick)) { context in
                            let elapsed = context.date.timeIntervalSince(answering.since)
                            Text(written?.thinking == true && written?.text.isEmpty == true ? Wording.thinking
                                : Wording.turnProgressLine(progress, begun: written?.begun ?? answering.progress.begun,
                                                           elapsed: elapsed >= Style.readingTimeShownAfter ? elapsed : nil))
                        }
                    } else {
                        Text(Wording.turnProgressLine(progress))
                    }
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let text = written?.text, !text.isEmpty {
                    Answer(text: text)
                }
            }
        }
    }
}

/// The documents an answer found outside the task when it was asked for more: what it looked for, then each document, to
/// add to the task, or every one at once.
private struct FindingView: View {
    @Environment(AppModel.self) private var model
    let finding: TurnFinding
    let task: SearchTask
    let documents: [Int64: ListedDocument]

    var body: some View {
        let found = finding.documents.compactMap { documents[$0] }
        let missing = found.compactMap(\.id).filter { !task.documents.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Wording.found(finding)).foregroundStyle(.secondary)
                Spacer()
                if missing.count > 1 {
                    Button(Wording.addAll) { add(missing) }.buttonStyle(.link)
                }
            }
            .font(.callout)
            ForEach(found, id: \.id) { document in
                HStack(spacing: Style.rowAccessorySpacing) {
                    ListRow(symbol: document.record.status.symbol, tint: document.record.status.tint, title: document.record.filename,
                            detail: document.date, subtitle: document.labels)
                        .openAction { model.open(document.record.path) }
                        .help(Wording.doubleClickToOpen)
                    if let id = document.id, task.documents.contains(id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.tasksList).help(Wording.inTaskAlready)
                    } else if let id = document.id {
                        Button { add([id]) } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help(Wording.addFoundHelp)
                            .accessibilityLabel(Wording.addFoundHelp)
                    }
                }
            }
        }
    }

    private func add(_ ids: [Int64]) {
        let id = task.id
        Task<Void, Never> { await model.perform(Wording.addToTaskAction) { _ = try await $0.searchTasks.add(id, documents: ids) } }
    }
}
