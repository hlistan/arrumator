import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Logic: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The archive's logic: the prompt the model follows when it decides where documents go and what they are "
            + "called. Each archive has its own, kept in the archive.",
        subcommands: [Show.self, Edit.self, Reset.self], defaultSubcommand: Show.self)

    struct Show: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let logic = try await runtime.logic.current()
            let file = try await runtime.records.logicFileURL()
            options.emit(logic) {
                guard let logic else { return "This archive has no logic yet." }
                let origin = logic.followsBuiltin ? "the built-in logic, kept up to date with Arrumator" : "edited"
                return "# Logic of \(runtime.archive.path) (\(origin))\n\(file.map { "Kept in \($0.path)\n" } ?? "")\n\(logic.body)"
            }
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace the archive's logic with a prompt from a file. Try it with `arrumatorcli rethink start --trial`, "
                + "then reprocess with `arrumatorcli rethink start`.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "File holding the prompt (Markdown or plain text).") var file: String
        func run() async throws {
            let body = try String(contentsOf: URL(fileURLWithPath: file.expandingTilde), encoding: .utf8)
            let logic = try await options.runtime().logic.update(body: body)
            options.emit(logic) { "Saved the logic. New documents follow it from now on." }
        }
    }

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restore the archive's logic to the text that ships with Arrumator.")
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let logic = try await options.runtime().resetLogic()
            options.emit(logic) { "The logic is the built-in text again, and follows new versions of Arrumator." }
        }
    }
}

struct Senders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Senders the app has learned: names, identifiers and usual folders.")
    @OptionGroup var options: GlobalOptions
    func run() async throws {
        let runtime = try await options.runtime()
        let senders = try await runtime.learningStore.correspondents().sorted { $0.filedCount > $1.filedCount }
        let rules = try await runtime.learningStore.rules().filter { !$0.forgotten }
        let taxonomy = try await runtime.taxonomy.snapshot(root: await runtime.settings.current.archiveURL)
        options.emit(senders) {
            senders.isEmpty ? "No senders learned yet." : Terminal.table(senders.map { c in
                let own = rules.filter { $0.senderID == c.id }
                return ["#\(c.id)", c.canonicalName, "\(c.filedCount) filed",
                        c.defaultFolderCode.flatMap { taxonomy.path(ofCode: $0) }.map { "usually \($0)" } ?? "",
                        own.isEmpty ? "no rules" : Format.count(own.count, "rule"),
                        c.aliases.isEmpty ? "" : "also “" + c.aliases.joined(separator: "”, “") + "”"]
            })
        }
    }
}

struct Forget: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make the app forget something it learned.",
        subcommands: [Example.self, Rule.self, Alias.self, Sender.self])

    struct Example: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop using a document as an example of where documents like it go.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Document id or file path.") var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            try await runtime.learner.forget(.example(documentID: try await resolveDocument(document, runtime: runtime)))
        }
    }

    struct Rule: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget a rule; it does not form again from the same filings.")
        @OptionGroup var options: GlobalOptions
        @Argument var id: Int64
        func run() async throws { try await options.runtime().learner.forget(.rule(id: id)) }
    }

    struct Alias: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget another name taught for a sender.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Sender number from `arrumatorcli senders`.") var sender: Int64
        @Argument var alias: String
        func run() async throws { try await options.runtime().learner.forget(.alias(correspondentID: sender, alias: alias)) }
    }

    struct Sender: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget everything known about a sender, and the rules about it.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Sender number from `arrumatorcli senders`.") var sender: Int64
        func run() async throws { try await options.runtime().learner.forget(.sender(correspondentID: sender)) }
    }
}

struct Rethink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Decide processed documents again from the archive's logic, review the plan, then apply or discard it.",
        subcommands: [Start.self, Status.self, Plan.self, Stop.self, Keep.self, Apply.self, Discard.self], defaultSubcommand: Status.self)

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start rethinking. Planning runs in the background of the app or `arrumatorcli run`, or here with --now.")
        @OptionGroup var options: GlobalOptions
        @Flag(help: "Only a few documents from across the archive, to try the logic.") var trial = false
        @Flag(help: "Also rethink documents you placed or confirmed yourself.") var includeUserPlaced = false
        @Flag(help: "Plan every document now, in this process.") var now = false
        func run() async throws {
            let runtime = try await options.runtime()
            let run = try await runtime.rethink.begin(trial ? .trial : .all, includeUserPlaced: includeUserPlaced)
            if now {
                _ = await runtime.lifecycle.ensureRunning()
                try await runtime.rethink.planAll()
            }
            let progress = await runtime.rethink.progress
            options.emit(run) { Rethink.describe(progress) }
        }
    }

    struct Status: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let run = try await RethinkStore(database: runtime.database).latestRun()
            options.emit(run) {
                guard let run else { return "No rethink yet. Start one with `arrumatorcli rethink start`." }
                return "#\(run.id ?? 0) \(run.status.rawValue) · started \(Format.date(run.startedAt))\n\(run.summary ?? "")"
            }
        }
    }

    struct Plan: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List what the current rethink would change.")
        @OptionGroup var options: GlobalOptions
        @Flag(help: "Also list documents that stay where they are.") var all = false
        func run() async throws {
            let runtime = try await options.runtime()
            let store = RethinkStore(database: runtime.database)
            guard let run = try await store.activeRun(), let runID = run.id else { throw RethinkError.noActiveRun }
            let statuses: Set<RethinkItemStatus>? = all ? nil : [.move, .unsure, .failed]
            let items = try await store.items(runID: runID, statuses: statuses)
            let archive = await runtime.settings.current.archiveURL.path + "/"
            let relative = { (path: String) in path.hasPrefix(archive) ? String(path.dropFirst(archive.count)) : path }
            options.emit(items) {
                Terminal.table(items.map { item in
                    ["#\(item.id ?? 0)", item.status.rawValue, item.selected ? "" : "kept", relative(item.fromPath),
                     item.targetPath.map { "→ " + relative($0) } ?? (item.error ?? "")]
                })
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop planning early: what has been decided becomes the plan, to apply or discard; the rest stay where they are.")
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let run = try await runtime.rethink.stopPlanning()
            let progress = await runtime.rethink.progress
            options.emit(run) { (run.summary ?? "") + "\n" + Rethink.describe(progress) }
        }
    }

    struct Keep: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Leave one document where it is when the plan is applied, or with --undo move it: a planned move, "
                + "or an unsure document to the place the logic suggested.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Item number from `rethink plan`.") var item: Int64
        @Flag(help: "Move it after all.") var undo = false
        func run() async throws { try await options.runtime().rethink.select(itemID: item, undo) }
    }

    struct Apply: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let run = try await options.runtime().rethink.apply()
            options.emit(run) { run.summary ?? "Applied" }
        }
    }

    struct Discard: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws { try await options.runtime().rethink.discard() }
    }

    static func describe(_ p: RethinkProgress) -> String {
        switch p.status {
        case .planning: "Rethinking: \(p.decided) of \(p.total) decided. Planning continues while the app or `arrumatorcli run` is running; "
            + "see the decisions so far with `arrumatorcli rethink plan --all`, and stop early with `arrumatorcli rethink stop`."
        case .ready: "Plan ready: \(Format.count(p.moves, "document")) would move, \(p.choices) can be chosen. "
            + "Review it with `arrumatorcli rethink plan`, then `apply` or `discard`."
        case .settled: "Nothing to change: the logic agrees with where these documents are."
        default: p.status.map { "Rethink \($0.rawValue)" } ?? "No rethink"
        }
    }
}
