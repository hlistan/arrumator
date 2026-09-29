import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Documents waiting for a decision, and actions on any document.",
        subcommands: [List.self, Approve.self, Move.self, Rename.self, Undo.self, Retry.self, Hold.self, MarkCorrect.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let docs = try await runtime.services.documents.reviewQueue()
            let taxonomy = try await runtime.taxonomy.snapshot(root: await runtime.settings.current.archiveURL)
            options.emit(docs) {
                docs.isEmpty ? "Nothing to review." : Terminal.table(docs.map { d in
                    let proposal = d.decision.flatMap { Terminal.target(of: $0, in: taxonomy) } ?? "—"
                    return ["#\(d.id ?? 0)", d.status.rawValue, proposal, Format.percent(d.confidence), d.filename,
                            d.decision?.reviewReasons.joined(separator: "; ") ?? ""]
                })
            }
        }
    }

    struct Approve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Accept the proposed folder (creating it if it is new).")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            try await runtime.review.approve(try await resolveDocument(document, runtime: runtime))
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a document to a folder (recorded as a correction).")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        @Argument(help: "Folder code, e.g. F12.") var folder: String
        func run() async throws {
            let runtime = try await options.runtime()
            let settings = await runtime.settings.current
            guard let target = try await runtime.taxonomy.snapshot(root: settings.archiveURL).folder(code: folder) else {
                throw ValidationError("No folder \(folder)")
            }
            try await runtime.review.move(try await resolveDocument(document, runtime: runtime), toFolder: target.id)
        }
    }

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Give a document a new file name (recorded as a correction).")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        @Argument(help: "New file name without extension.") var name: String
        func run() async throws {
            let runtime = try await options.runtime()
            try await runtime.review.edit(try await resolveDocument(document, runtime: runtime), fileName: name, title: nil,
                                          correspondent: nil, date: nil, type: nil)
        }
    }

    struct Undo: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a filed document back to Incoming and forget what was learned from it.")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            try await runtime.review.undo(try await resolveDocument(document, runtime: runtime))
        }
    }

    struct Retry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Decide again (e.g. after changing models) and file.")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            try await runtime.review.refile(try await resolveDocument(document, runtime: runtime))
            await runtime.coordinator.drain()
        }
    }

    struct Hold: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Leave a document where it is for later.")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            try await runtime.review.hold(try await resolveDocument(document, runtime: runtime))
        }
    }

    struct MarkCorrect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "mark-correct", abstract: "Confirm an automatic filing was right.")
        @OptionGroup var options: GlobalOptions
        @Argument var document: String
        func run() async throws {
            let runtime = try await options.runtime()
            try await runtime.review.markCorrect(try await resolveDocument(document, runtime: runtime))
        }
    }
}

struct Folders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The folder tree as it has grown, and manual folder creation.",
                                                    subcommands: [Tree.self, Create.self], defaultSubcommand: Tree.self)

    struct Tree: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let snapshot = try await runtime.taxonomy.snapshot(root: await runtime.settings.current.archiveURL)
            options.emit(snapshot) {
                guard !snapshot.folders.isEmpty else { return "The archive is empty; folders appear as documents arrive." }
                return snapshot.outline().map { folder, depth in
                    let indent = String(repeating: "   ", count: depth - 1)
                    return "\(indent)\(folder.name)\(folder.yearSubfolders ? " [by year]" : "") · \(folder.documentCount) docs · "
                        + "\(folder.origin.rawValue) · \(folder.code)" + (folder.description.isEmpty ? "" : "\n\(indent)   \(folder.description)")
                }.joined(separator: "\n")
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a folder at any depth, with the folders above it that do not exist yet.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "Folder names from the top of the archive, separated by /, e.g. \"Portugal/Acme Lda/Banking\".") var path: String
        @Option(help: "What belongs in the last folder of the path.") var description: String
        @Flag(help: "Split into year subfolders.") var yearly = false

        func run() async throws {
            let names = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !names.isEmpty else { throw ValidationError("Give the folder's path, e.g. --path \"Home/Utilities\"") }
            let runtime = try await options.runtime()
            let levels = names.enumerated().map { index, name in
                FolderLevel(name: name, description: index == names.count - 1 ? description : "")
            }
            let folder = try await runtime.taxonomy.materialize(
                FolderSpec(parentCode: nil, levels: levels, yearSubfolders: yearly, yearRule: yearly ? .documentDate : nil),
                root: await runtime.settings.current.archiveURL, origin: .user)
            options.emit(folder) { "Created \(folder.relativePath)" }
        }
    }
}

struct Rules: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rules learned from use.",
                                                    subcommands: [List.self, Enable.self, Disable.self],
                                                    defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let rules = try await runtime.learningStore.rules().filter { !$0.forgotten }
            let senders = Correspondent.names(try await runtime.learningStore.correspondents())
            options.emit(rules) {
                rules.isEmpty ? "No rules yet; they form as documents are filed." : Terminal.table(rules.map { r in
                    ["#\(r.id)", r.enabled ? "on" : "off", r.origin.rawValue, String(format: "%.2f", r.reliability),
                     "support \(r.support) hits \(r.hits) contra \(r.contradictions)", r.name,
                     "when " + r.condition { senders[$0] }]
                })
            }
        }
    }

    struct Enable: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        @Argument var id: Int64
        func run() async throws { try await Rules.toggle(options, id, enabled: true) }
    }

    struct Disable: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        @Argument var id: Int64
        func run() async throws { try await Rules.toggle(options, id, enabled: false) }
    }

    static func toggle(_ options: GlobalOptions, _ id: Int64, enabled: Bool) async throws {
        let runtime = try await options.runtime()
        guard var rule = try await runtime.learningStore.rules().first(where: { $0.id == id && !$0.forgotten }) else {
            throw ValidationError("No rule \(id)")
        }
        rule.enabled = enabled
        rule.confirmed = true
        try await runtime.learningStore.saveRule(rule)
    }
}

struct Proposals: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Improvements the app suggests (folder descriptions, rules).",
                                                    subcommands: [List.self, Accept.self, Reject.self], defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        func run() async throws {
            let runtime = try await options.runtime()
            let pending = try await runtime.proposals.pending()
            options.emit(pending) {
                pending.isEmpty ? "No pending proposals." : pending.map { "#\($0.id ?? 0) [\($0.kind)] \($0.title)\n    \($0.payloadJson.prefix(300))" }
                    .joined(separator: "\n")
            }
        }
    }

    struct Accept: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        @Argument var id: Int64
        func run() async throws { try await options.runtime().proposals.accept(id) }
    }

    struct Reject: AsyncParsableCommand {
        @OptionGroup var options: GlobalOptions
        @Argument var id: Int64
        func run() async throws { try await options.runtime().proposals.reject(id) }
    }
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
        abstract: "The archive documents are filed into. Each archive keeps its own logic, folders and what was learned, "
            + "and has an index of its own.",
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
            abstract: "File into another archive from now on, with its own logic. A folder never used as an archive "
                + "starts with the built-in logic; one that was is opened as it was left.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The archive's folder; created if it does not exist.") var path: String
        func run() async throws {
            let next = try await options.runtime().switchArchive(to: path)
            try await next.openArchive()
            let summary = try await next.summary()
            options.emit(summary) { "Switched archives. A running app keeps its archive until it is restarted.\n" + Archive.describe(summary) }
        }
    }

    static func describe(_ summary: ArchiveSummary) -> String {
        ["Archive: \(summary.archive)", "Index: \(summary.index)",
         "Logic: \(summary.logicFile ?? "not written yet")"
            + (summary.logicFollowsBuiltin ? " (built in)" : " (edited)")].joined(separator: "\n")
    }
}
