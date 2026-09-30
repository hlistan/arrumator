import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Documents waiting for you, and what you can do with any document.",
        subcommands: [List.self, Confirm.self, Rename.self, Retry.self, Hold.self, Undo.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let docs = try await runtime.services.documents.reviewQueue()
            options.emit(docs) {
                docs.isEmpty ? "Nothing to review." : Terminal.table(docs.map { d in
                    ["#\(d.id ?? 0)", d.status.rawValue, d.filename, d.analysis?.problems.joined(separator: "; ") ?? ""]
                })
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
            abstract: "Read a document again with the model (after changing models, say): its labels and name.")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            _ = await runtime.lifecycle.ensureRunning()
            let id = try await resolveDocument(document, runtime: runtime)
            try await runtime.review.retry(id)
            await runtime.coordinator.drain()
            try await report(id, runtime: runtime, options: options)
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
    options.emit(document) { "#\(id) \(document.status.rawValue): \(document.path)" }
}

struct Rebuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rebuild the index from the archive's record files. Changes not yet written to them are written first; "
            + "documents then have their text read again in the background of the app or `arrumatorcli run`.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let summary = try await options.runtime().records.rebuildIndex()
        options.emit(summary) { summary.summary + ". \(summary.queued) documents queued to be read again." }
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
            options.emit(summary) { Archive.describe(summary) }
        }
    }

    struct Switch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "File into another archive from now on. A folder that was an archive is opened as it was left.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The archive's folder; created if it does not exist.") var path: String
        func run() async throws {
            let next = try await options.runtime().switchArchive(to: path)
            try await next.openArchive()
            let summary = next.summary()
            options.emit(summary) { "Switched archives. A running app keeps its archive until it is restarted.\n" + Archive.describe(summary) }
        }
    }

    static func describe(_ summary: ArchiveSummary) -> String {
        ["Archive: \(summary.archive)", "Index: \(summary.index)"].joined(separator: "\n")
    }
}
