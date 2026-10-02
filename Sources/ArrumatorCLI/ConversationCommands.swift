import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

extension Tasks {
    /// Answers every question in the queue until it is empty, as the app's queue does in the background.
    static func runConversation(_ runtime: ArrumatorRuntime) async {
        _ = await runtime.lifecycle.ensureRunning()
        await runtime.conversationQueue.drain()
    }

    /// A question and its answer, with the names of the documents it names, or an error naming the question.
    static func answered(_ id: Int64, runtime: ArrumatorRuntime) async throws -> Answered {
        guard let turn = try await runtime.conversations.store.turn(id: id) else { throw ConversationError.turnNotFound(id) }
        return Answered(turn: turn, documents: try await names(of: [turn], runtime: runtime))
    }

    /// The documents the answers draw on and found, by number and name, the lowest number first; those the archive no
    /// longer has are left out.
    static func names(of turns: [TaskTurn], runtime: ArrumatorRuntime) async throws -> [NamedDocument] {
        let ids = Set(turns.flatMap { $0.sources + ($0.finding?.documents ?? []) }).sorted()
        return try await runtime.services.documents.documents(ids: ids).compactMap { d in d.id.map { NamedDocument(id: $0, name: d.filename) } }
    }

    /// A document an answer names, by number and name.
    struct NamedDocument: Codable, Hashable {
        var id: Int64
        var name: String
    }

    /// A question and its answer as the command line gives it, with the documents it names.
    struct Answered: Codable {
        var turn: TaskTurn
        var documents: [NamedDocument]
    }

    struct Ask: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask about a task's documents in your own words: summarize, translate, compare, draft from them, or find more like them. Answered from the set as it is then.")
        @OptionGroup var options: GlobalOptions
        @Flag(help: "Only put the question in the queue; the app, `run` or `tasks answer` answers it.") var queueOnly = false
        @Argument(help: "The task's number, as `tasks list` shows it.") var task: Int64
        @Argument(parsing: .remaining, help: "What you want to know or have, such as: what do these invoices come to in all?") var question: [String]

        func run() async throws {
            let runtime = try await options.runtime()
            let turn = try await runtime.conversations.ask(task, question: question.joined(separator: " "))
            if !queueOnly { await Tasks.runConversation(runtime) }
            let answered = try await Tasks.answered(turn.id, runtime: runtime)
            options.emit(answered) { Terminal.turn(answered.turn, documents: answered.documents) }
        }
    }

    struct Answer: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Answer every question in the queue now.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let runtime = try await options.runtime()
            await Tasks.runConversation(runtime)
            let waiting = try await runtime.conversations.store.queuedCount()
            options.emit(Waiting(waiting: waiting)) { waiting == 0 ? "No question waits." : "\(Format.count(waiting, "question")) still wait." }
        }
    }

    /// How many questions still wait to be answered.
    struct Waiting: Codable {
        var waiting: Int
    }

    /// How many questions were removed.
    struct Removed: Codable {
        var removed: Int
    }

    struct Conversation: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "A task's conversation: each question and its answer, the documents it draws on and found, and the changes made to the set between them.")
        @OptionGroup var options: GlobalOptions
        @Flag(help: "Also show how each answer was made: what it was shown, the prompts and the model's raw answers.") var full = false
        @Argument(help: "The task's number.") var task: Int64

        func run() async throws {
            let runtime = try await options.runtime()
            guard try await runtime.searchTasks.store.task(id: task) != nil else { throw SearchTaskError.taskNotFound(task) }
            let items = try await runtime.conversations.store.conversation(task: task)
            let turns = items.compactMap(\.turn)
            let documents = try await Tasks.names(of: turns, runtime: runtime)
            var traces: [TurnTrace] = []
            if full {
                for turn in turns {
                    if let id = turn.lastTrace, let trace = try await runtime.traces.trace(id: id) {
                        traces.append(TurnTrace(turn: turn.id, trace: TraceExport(trace: trace.0, steps: trace.1)))
                    }
                }
            }
            options.emit(Full(items: items, documents: documents, traces: full ? traces : nil)) {
                guard !items.isEmpty else { return "No questions yet; `arrumatorcli tasks ask \(task) <question>` asks one." }
                return items.map { item in
                    guard let turn = item.turn else { return "— \(Format.date(item.at)) · \(item.change ?? "")" }
                    let trace = traces.first { $0.turn == turn.id }.map { "\n\n" + Terminal.steps($0.trace.steps, full: true) } ?? ""
                    return Terminal.turn(turn, documents: documents) + trace
                }.joined(separator: "\n\n")
            }
        }

        struct Full: Encodable {
            var items: [ConversationItem]
            var documents: [NamedDocument]
            /// With `--full`, how each answer was made, by its question's number.
            var traces: [TurnTrace]?
        }

        struct TurnTrace: Encodable {
            var turn: Int64
            var trace: TraceExport
        }
    }

    struct AskAgain: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask a question again, answered or not: its answer is replaced by one drawn from the set as it is now.")
        @OptionGroup var options: GlobalOptions
        @Flag(help: "Only put the question in the queue; the app, `run` or `tasks answer` answers it.") var queueOnly = false
        @Argument(help: "The question's number, as `tasks conversation` shows it.") var question: Int64

        func run() async throws {
            let runtime = try await options.runtime()
            _ = try await runtime.conversations.askAgain(question)
            if !queueOnly { await Tasks.runConversation(runtime) }
            let answered = try await Tasks.answered(question, runtime: runtime)
            options.emit(answered) { Terminal.turn(answered.turn, documents: answered.documents) }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a question waiting to be answered or being answered, which then keeps nothing of its answer; either can be asked again.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The question's number, as `tasks conversation` shows it.") var question: Int64

        func run() async throws {
            let runtime = try await options.runtime()
            try await runtime.conversations.stop(question)
            let answered = try await Tasks.answered(question, runtime: runtime)
            options.emit(answered) { Terminal.turn(answered.turn, documents: answered.documents) }
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove every question about a task's documents and its answer.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The task's number.") var task: Int64

        func run() async throws {
            let runtime = try await options.runtime()
            let removed = try await runtime.conversations.clear(task)
            options.emit(Removed(removed: removed)) { "Removed \(Format.count(removed, "question")) about task #\(task)" }
        }
    }
}

extension Terminal {
    /// A question and its answer: its number, state, the model that answered and when it was asked; the question quoted;
    /// the answer; the documents it draws on and those it found outside the set, by number and name; and why it is
    /// incomplete or not answered.
    static func turn(_ turn: TaskTurn, documents: [Tasks.NamedDocument]) -> String {
        func named(_ ids: [Int64]) -> String {
            ids.map { id in "#\(id) " + (documents.first { $0.id == id }?.name ?? "(no longer in the archive)") }.joined(separator: " · ")
        }
        var lines = ["Question #\(turn.id) · \(turn.state.rawValue)" + (turn.model.map { " · \($0)" } ?? "") + " · \(Format.date(turn.asked))"]
        lines += turn.question.components(separatedBy: .newlines).map { "> " + $0 }
        if let answer = turn.answer { lines += ["", answer] }
        if !turn.sources.isEmpty { lines += ["", "Drawn from: " + named(turn.sources)] }
        if let finding = turn.finding {
            let found = finding.documents.isEmpty ? "nothing outside the set"
                : "\(Format.count(finding.documents.count, "document")) outside the set: " + named(finding.documents)
                    + "\n  add them with: arrumatorcli tasks add \(turn.task) " + finding.documents.map(String.init).joined(separator: " ")
            lines += ["", "Looked for “\(finding.request)”: " + (finding.problem ?? found)]
        }
        if let problem = turn.problem { lines += ["", (turn.state == .failed ? "Not answered: " : "Incomplete: ") + problem] }
        return lines.joined(separator: "\n")
    }
}
