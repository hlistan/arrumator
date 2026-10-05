import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Documents waiting for you, those you set aside, and what you can do with any document.",
        subcommands: [List.self, Confirm.self, Rename.self, Retry.self, Hold.self, Undo.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let listed = try await runtime.services.documents.needsYou()
            let rows = { (docs: [DocumentRecord]) in
                Terminal.table(docs.map { d in ["#\(d.id ?? 0)", d.status.rawValue, d.filename, d.analysis?.problems.joined(separator: "; ") ?? ""] })
            }
            try options.emit(listed) {
                let waiting = listed.waiting.isEmpty ? "Nothing waits for you." : rows(listed.waiting)
                return listed.setAside.isEmpty ? waiting : waiting + "\n\nSet aside by you (left for later or undone):\n" + rows(listed.setAside)
            }
        }
    }

    struct Confirm: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Confirm a document as it is: its name and labels are right. One waiting for you is filed.")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            let id = try await resolveDocument(document, runtime: runtime)
            try await runtime.review.confirm(id)
            try await report(id, runtime: runtime, options: options)
        }
    }

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Give a document a new file name (recorded as a correction).")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        @Argument(help: "New file name without extension.") var name: String
        func run() async throws {
            let runtime = try await options.runtime()
            let id = try await resolveDocument(document, runtime: runtime)
            try await runtime.review.edit(id, fileName: name, labels: nil)
            try await report(id, runtime: runtime, options: options)
        }
    }

    struct Retry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read a document again from its file with the profile in use (after changing models, say): its labels, "
                + "name, text and meaning take the place of those it had once it is read. --all reads every document of the "
                + "archive again, after the files that arrive meanwhile.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The document to read again; none with --all.") var document: String?
        @Flag(help: "Read every document of the archive again: filed, waiting for you or failed, but not one left for later.")
        var all = false
        @Flag(help: "Only put it in the queue; the app or `run` reads it.") var queueOnly = false

        func validate() throws {
            if all == (document != nil) { throw ValidationError("Name one document to read again, or give --all for every one.") }
        }

        func run() async throws {
            let runtime = try await options.runtime()
            if !queueOnly { _ = await runtime.lifecycle.ensureRunning() }
            guard let document else {
                let ids = try await runtime.review.retryAll()
                if !queueOnly { await runtime.coordinator.drain(whileOllamaAnswers: true) }
                let documents = try await runtime.services.documents.documents(ids: ids)
                let left = try await runtime.services.jobs.counts().readingAgain
                try options.emit(documents) { Self.said(documents, left: left) }
                return
            }
            let id = try await resolveDocument(document, runtime: runtime)
            try await runtime.review.retry(id)
            if !queueOnly { await runtime.coordinator.drain() }
            try await report(id, runtime: runtime, options: options)
        }

        /// What `--all` prints: each document queued now, as it is now, then how many were, and how many documents, `left`,
        /// are still to be read, by the app or `run`, as with `--queue-only` or while Ollama is away.
        static func said(_ documents: [DocumentRecord], left: Int) -> String {
            guard !documents.isEmpty else { return "No document to queue: every document of the archive waits to be read already, or it has none." }
            let rows = documents.map { "#\($0.id ?? 0) \($0.status.rawValue): \($0.path)" }
            let total = Format.count(documents.count, "document")
            let said = left == 0 ? "Read \(total) again." : "\(total) queued to be read again, after the files that arrive meanwhile; "
                + "\(left) still to be read by the app or `arrumatorcli run`."
            return (rows + [said]).joined(separator: "\n")
        }
    }

    struct Hold: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Leave a document where it is for later.")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            let id = try await resolveDocument(document, runtime: runtime)
            try await runtime.review.hold(id)
            try await report(id, runtime: runtime, options: options)
        }
    }

    struct Undo: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a filed document back to Incoming, held there.")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            let id = try await resolveDocument(document, runtime: runtime)
            try await runtime.review.undo(id)
            try await report(id, runtime: runtime, options: options)
        }
    }
}

/// What a command that changed a document prints: the document as it is now.
func report(_ id: Int64, runtime: ArrumatorRuntime, options: GlobalOptions) async throws {
    guard let document = try await runtime.services.documents.document(id: id) else { throw ValidationError("No document \(id)") }
    try options.emit(document) { "#\(id) \(document.status.rawValue): \(document.path)" }
}

struct Rebuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rebuild the index from the archive's record files. Changes not yet written to them are written first; "
            + "documents then have their text read again in the background of the app or `arrumatorcli run`. A record file that "
            + "cannot be read stops it before anything changes, naming the file.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let summary = try await options.runtime().records.rebuild()
        try options.emit(summary) { summary.summary + ". \(summary.queued) documents queued to be read again." }
    }
}

struct Archive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The archive documents are filed into. Each archive keeps its own history and has an index of its own.",
        subcommands: [Show.self, Switch.self], defaultSubcommand: Show.self)

    struct Show: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let summary = try await options.runtime().summary()
            try options.emit(summary) { Archive.describe(summary) }
        }
    }

    struct Switch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "File into another archive from now on. A folder that was an archive is opened as it was left.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The archive's folder; made when it is not there and no index has held an archive in it, never in place of one that is away.") var path: String
        func run() async throws {
            let switched = try await options.runtimeEvenIfUnread().switchArchive(to: path)
            // Said on standard error, so the output stays one JSON document with --json.
            if let unwritten = switched.unwritten { FileHandle.standardError.write(Data((unwritten.note + "\n").utf8)) }
            let next = switched.runtime
            try await next.openArchive()
            let summary = next.summary()
            try options.emit(summary) { "Switched archives. A running app keeps its archive until it is restarted.\n" + Archive.describe(summary) }
        }
    }

    static func describe(_ summary: ArchiveSummary) -> String {
        ["Archive: \(summary.archive)", "Index: \(summary.index)"].joined(separator: "\n")
    }
}
