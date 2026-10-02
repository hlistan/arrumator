import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Tasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search tasks: ask for documents in your own words, look the set over, edit it, export it.",
        subcommands: [List.self, New.self, Show.self, Run.self, Update.self, Retry.self, Add.self, Remove.self, Export.self, Delete.self],
        defaultSubcommand: List.self)

    /// The task and its set, arranged, or an error naming the task.
    static func detail(_ id: Int64, runtime: ArrumatorRuntime) async throws -> SearchTaskDetail {
        guard let detail = try await runtime.searchTasks.store.detail(id: id) else { throw SearchTaskError.taskNotFound(id) }
        return detail
    }

    /// Runs the queue until it is empty, as the app's queue does in the background.
    static func runQueue(_ runtime: ArrumatorRuntime) async {
        _ = await runtime.lifecycle.ensureRunning()
        await runtime.taskQueue.drain()
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Every search task, the most recently asked first.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let runtime = try await options.runtime()
            let tasks = try await runtime.searchTasks.store.tasks()
            let settings = await runtime.settings.current
            options.emit(tasks) {
                tasks.isEmpty ? "No search tasks yet; `arrumatorcli tasks new <what you need>` asks for documents."
                    : Terminal.table(tasks.map { Terminal.taskRow($0, settings: settings) })
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask for documents in your own words: the model reads the request, and the documents it asks for are found and arranged.")
        @OptionGroup var options: GlobalOptions
        @Flag(help: "Only put the task in the queue; the app, `run` or `tasks run` finds its documents.") var queueOnly = false
        @Option(help: "How much the model thinks before it answers the request: low (not at all), medium or high (the most); Settings' effort for new tasks if not given.")
        var effort: TaskEffort?
        @Option(help: "The model profile that reads the request, by its id as `arrumatorcli profiles` lists it; if not given, the one Settings uses when it is read.")
        var profile: String?
        @Argument(parsing: .remaining, help: "What you need, such as: electricity invoices from 2025, by sender.") var prompt: [String]

        func run() async throws {
            let runtime = try await options.runtime()
            let task = try await runtime.searchTasks.create(prompt: prompt.joined(separator: " "), effort: effort, profile: profile)
            if !queueOnly { await Tasks.runQueue(runtime) }
            let detail = try await Tasks.detail(task.id, runtime: runtime)
            let settings = await runtime.settings.current
            options.emit(detail) { Terminal.detail(detail, settings: settings) }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "A search task: what it asks for, how the model read it, its documents arranged by their labels, the newest by their own date first, and its exports.")
        @OptionGroup var options: GlobalOptions
        @Flag(help: "Also show how the model read the request: the prompts and its raw answers.") var full = false
        @Argument(help: "The task's number, as `tasks list` shows it.") var task: Int64

        func run() async throws {
            let runtime = try await options.runtime()
            let detail = try await Tasks.detail(task, runtime: runtime)
            let settings = await runtime.settings.current
            guard full else {
                options.emit(detail) { Terminal.detail(detail, settings: settings) }
                return
            }
            var trace: (TraceRecord, [TraceStepRecord])?
            if let id = detail.task.lastTrace { trace = try await runtime.traces.trace(id: id) }
            options.emit(Full(detail: detail, trace: trace.map { TraceExport(trace: $0.0, steps: $0.1) })) {
                Terminal.detail(detail, settings: settings) + "\n\n"
                    + (trace.map { Terminal.steps($0.1, full: true) } ?? "The request has not been read yet.")
            }
        }

        struct Full: Encodable {
            var detail: SearchTaskDetail
            var trace: TraceExport?
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Find the documents of every task in the queue now.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let runtime = try await options.runtime()
            await Tasks.runQueue(runtime)
            let tasks = try await runtime.searchTasks.store.tasks()
            let settings = await runtime.settings.current
            options.emit(tasks) { tasks.isEmpty ? "No search tasks yet." : Terminal.table(tasks.map { Terminal.taskRow($0, settings: settings) }) }
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rename a task, arrange its set otherwise, or ask it for something else, with another effort or profile, which finds its documents again.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "The task's name; \"\" gives it the model's name back.") var title: String?
        @Option(help: "What the task asks for, in your own words.") var prompt: String?
        @Option(help: "How much the model thinks before it answers the request: low (not at all), medium or high (the most).") var effort: TaskEffort?
        @Option(help: "The model profile that reads the request, by its id as `arrumatorcli profiles` lists it; \"\" gives the task back to the one Settings uses.")
        var profile: String?
        @Option(help: "What the set is arranged by, outermost first, such as sender,date; `none` for no arrangement; `asked` for what the request asked.")
        var groupBy: String?
        @Flag(help: "Only put a changed task in the queue; the app, `run` or `tasks run` finds its documents.") var queueOnly = false
        @Argument(help: "The task's number.") var task: Int64

        func validate() throws {
            _ = try groupBy.map(Tasks.grouping)
            if title == nil && prompt == nil && groupBy == nil && effort == nil && profile == nil {
                throw ValidationError("Give --title, --prompt, --group-by, --effort or --profile")
            }
        }

        func run() async throws {
            let runtime = try await options.runtime()
            let updated = try await runtime.searchTasks.update(task, SearchTaskChange(title: title, prompt: prompt,
                                                                                    grouping: try groupBy.map(Tasks.grouping),
                                                                                    effort: effort, profile: profile))
            if updated.state.isActive && !queueOnly { await Tasks.runQueue(runtime) }
            let detail = try await Tasks.detail(task, runtime: runtime)
            let settings = await runtime.settings.current
            options.emit(detail) { Terminal.detail(detail, settings: settings) }
        }
    }

    /// `sender,date`, `none` or `asked` as an arrangement.
    static func grouping(_ text: String) throws -> SearchTaskChange.Grouping {
        switch text.trimmingCharacters(in: .whitespaces) {
        case "asked": return .asAsked
        case "none": return .by([])
        default:
            return .by(try text.split(separator: ",").map { word in
                let name = word.trimmingCharacters(in: .whitespaces)
                guard let kind = LabelKind(rawValue: name) else {
                    throw ValidationError("“\(name)” is no kind of label; the kinds are " + LabelKind.allCases.map(\.rawValue).joined(separator: ", "))
                }
                return kind
            })
        }
    }

    struct Retry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Find a task's documents again, as after new documents were filed or the model could not read it.")
        @OptionGroup var options: GlobalOptions
        @Flag(help: "Only put the task in the queue; the app, `run` or `tasks run` finds its documents.") var queueOnly = false
        @Argument(help: "The task's number.") var task: Int64

        func run() async throws {
            let runtime = try await options.runtime()
            try await runtime.searchTasks.retry(task)
            if !queueOnly { await Tasks.runQueue(runtime) }
            let detail = try await Tasks.detail(task, runtime: runtime)
            let settings = await runtime.settings.current
            options.emit(detail) { Terminal.detail(detail, settings: settings) }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add documents to a task's set: by number or path, or every document that has all the labels given, at most tasks.maxDocuments, the newest by their own date.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "Add every document with this label, as kind=value, such as type=invoice (repeatable: all of them).")
        var label: [String] = []
        @Argument(help: "The task's number.") var task: Int64
        @Argument(help: "Documents, by number or file path.") var documents: [String] = []

        func validate() throws {
            _ = try label.map(Labels.label)
            if documents.isEmpty && label.isEmpty { throw ValidationError("Give documents, or --label to add those with the labels") }
        }

        func run() async throws {
            let runtime = try await options.runtime()
            var ids: [Int64] = []
            for document in documents { ids.append(try await resolveDocument(document, runtime: runtime)) }
            var added = try await runtime.searchTasks.add(task, documents: ids)
            if !label.isEmpty { added += try await runtime.searchTasks.add(task, labelled: try label.map(Labels.label)) }
            let detail = try await Tasks.detail(task, runtime: runtime)
            let settings = await runtime.settings.current
            options.emit(detail) { "Added \(Format.count(added.count, "document"))\n\n" + Terminal.detail(detail, settings: settings) }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Take documents out of a task's set; finding its documents again leaves them out.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The task's number.") var task: Int64
        @Argument(help: "Documents, by number or file path.") var documents: [String]

        func run() async throws {
            let runtime = try await options.runtime()
            var ids: [Int64] = []
            for document in documents { ids.append(try await resolveDocument(document, runtime: runtime)) }
            let removed = try await runtime.searchTasks.remove(task, documents: ids)
            let detail = try await Tasks.detail(task, runtime: runtime)
            let settings = await runtime.settings.current
            options.emit(detail) { "Took out \(Format.count(removed.count, "document"))\n\n" + Terminal.detail(detail, settings: settings) }
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy a task's set into a new folder named after it, a folder per label it is arranged by, or into a ZIP archive.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "The folder to put the export in, outside the archive and Incoming; made if it does not exist.") var to: String
        @Flag(help: "Pack the export into a ZIP archive.") var zip = false
        @Argument(help: "The task's number.") var task: Int64

        func run() async throws {
            let runtime = try await options.runtime()
            let folder = URL(fileURLWithPath: to.expandingTilde, isDirectory: true).standardizedFileURL
            let export = try await runtime.searchTasks.export(task, to: folder, format: zip ? .zip : .folder)
            options.emit(export) { Terminal.export(export) }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a task, its set and the record of its exports. What it exported stays where it was put.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The task's number.") var task: Int64

        func run() async throws {
            let runtime = try await options.runtime()
            guard let removed = try await runtime.searchTasks.store.task(id: task) else { throw SearchTaskError.taskNotFound(task) }
            try await runtime.searchTasks.delete(task)
            options.emit(removed) { "Removed task #\(removed.id) “\(removed.name)”" }
        }
    }
}

extension TaskEffort: ExpressibleByArgument {}

extension Terminal {
    /// A task on one line of a table: number, state, effort, the profile that reads it, how many documents and exports,
    /// name.
    static func taskRow(_ task: SearchTask, settings: AppSettings) -> [String] {
        ["#\(task.id)", task.state.rawValue, task.effort.rawValue, profile(task, settings: settings),
         Format.count(task.documents.count, "document"), Format.count(task.exports.count, "export"), task.name]
    }

    /// The profile that reads a task, by name: its own, or Settings' profile and which that is now. One the settings no
    /// longer list is named by its id.
    static func profile(_ task: SearchTask, settings: AppSettings) -> String {
        guard let id = task.profile else { return "Settings' profile (\(settings.modelProfiles[settings.profile]?.name ?? settings.profile))" }
        return settings.modelProfiles[id]?.name ?? "“\(id)”, which the settings no longer list"
    }

    /// A task, what it asks for and how it is read, its set arranged as it says, and its exports.
    static func detail(_ detail: SearchTaskDetail, settings: AppSettings) -> String {
        let task = detail.task
        var lines = ["#\(task.id) \(task.name) · \(task.state.rawValue) · \(Format.count(task.documents.count, "document"))",
                     "  asked:       \(task.prompt)"]
        lines.append("  read with:   \(task.effort.rawValue) effort, by \(profile(task, settings: settings))"
            + (task.model.map { "; last read by \($0)" } ?? ""))
        if let plan = task.plan { lines.append("  looked for:  \(Terminal.plan(plan))") }
        if let problem = task.problem { lines.append("  problem:     \(problem)") }
        lines.append("  arranged by: " + (task.grouping.isEmpty ? "nothing" : task.grouping.map(\.rawValue).joined(separator: " › "))
            + (task.groupedByUser ? " (yours)" : ""))
        if !task.removed.isEmpty { lines.append("  taken out:   " + task.removed.map { "#\($0)" }.joined(separator: " ")) }
        let tree = Terminal.tree(detail.tree, indent: 0)
        if !tree.isEmpty { lines += ["", tree] }
        if !task.exports.isEmpty { lines += [""] + task.exports.map(Terminal.export) }
        return lines.joined(separator: "\n")
    }

    /// What a plan asks for: “type invoice · topic electricity · date 2025; words: meter”.
    static func plan(_ plan: SearchPlan) -> String {
        let labels = plan.labels.map { "\($0.kind.rawValue) \(Terminal.label($0))" }.joined(separator: " · ")
        return labels + (plan.words.isEmpty ? "" : (labels.isEmpty ? "" : "; ") + "words: " + plan.words.joined(separator: ", "))
    }

    /// A group and everything below it, indented a level per kind.
    static func tree(_ group: LabelGroup, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = []
        for child in group.groups {
            let heading = child.kind.map { kind in child.value.map { Terminal.label(DocumentLabel(kind: kind, value: $0)) } ?? "no \(kind.rawValue)" }
            lines.append(pad + (heading ?? "") + " (\(child.count))")
            lines.append(tree(child, indent: indent + 2))
        }
        lines += group.documents.map { pad + "#\($0.id ?? 0) \($0.filename)" }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// An export: when, as what, where, and how much of the set it holds.
    static func export(_ export: SearchTaskExport) -> String {
        "Export #\(export.id) · \(Format.date(export.at)) · \(export.format.rawValue) · \(Format.count(export.files.count, "document"))"
            + (export.skipped.isEmpty ? "" : ", \(export.skipped.count) not copied") + "\n  \(export.path)"
            + export.skipped.map { "\n  #\($0.document) not copied: \($0.reason)" }.joined()
    }

    /// A trace's steps, one per line, with their inputs and outputs when `full`.
    static func steps(_ steps: [TraceStepRecord], full: Bool) -> String {
        var lines: [String] = []
        for s in steps {
            let seq = String(s.seq).padding(toLength: 3, withPad: " ", startingAt: 0)
            let stage = s.stage.padding(toLength: 13, withPad: " ", startingAt: 0)
            let status = s.status.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
            lines.append("\(seq) \(stage) \(status) \(Int(s.durationMs)) ms")
            if let e = s.error { lines.append("      error: \(e)") }
            if full {
                if let i = s.inputJson { lines.append("      in:  \(i)") }
                if let o = s.outputJson { lines.append("      out: \(o)") }
            } else if let o = s.outputJson {
                lines.append("      \(o.prefix(240))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
