import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Labels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Labels: a document's, the archive's, and the rules every reading follows.",
        subcommands: [Show.self, Unlabelled.self, List.self, Browse.self, Similar.self, Merge.self, Ignore.self, KeepApart.self, Rules.self,
                      Forget.self],
        defaultSubcommand: Show.self)

    /// `kind=value` as a label.
    static func label(_ text: String) throws -> DocumentLabel {
        let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = LabelKind(rawValue: parts[0].trimmingCharacters(in: .whitespaces)) else {
            throw ValidationError("“\(text)” is no kind=value; the kinds are " + LabelKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return DocumentLabel(kind: kind, value: parts[1])
    }

    struct Row: Encodable {
        var id: Int64
        var path: String
        /// Nil while the document has no labels and has not been labelled.
        var labels: [DocumentLabel]?
        /// Whether the document has been labelled; one that has not may have its tags, the user's own.
        var labelled: Bool

        init(_ document: DocumentRecord, id: Int64) {
            self.id = id
            path = document.path
            labels = document.labels
            labelled = document.isLabelled
        }
    }

    static func rows(_ ids: [Int64], runtime: ArrumatorRuntime) async throws -> [Row] {
        var rows: [Row] = []
        for id in ids {
            guard let doc = try await runtime.services.documents.document(id: id) else { throw ValidationError("No document \(id)") }
            rows.append(Row(doc, id: id))
        }
        return rows
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a document's labels, or correct them.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "Give the document this label, as kind=value, such as sender=EDP or topic=electricity (repeatable).")
        var add: [String] = []
        @Option(help: "Take this label, as kind=value, off the document (repeatable).") var remove: [String] = []
        @Argument(help: "Document id or file path.") var document: String

        func validate() throws {
            _ = try (add + remove).map(Labels.label)
        }

        func run() async throws {
            let runtime = try await options.runtime()
            let id = try await resolveDocument(document, runtime: runtime)
            if !(add.isEmpty && remove.isEmpty) {
                try await runtime.review.edit(id, fileName: nil,
                                              labels: LabelEdit(adding: try add.map(Labels.label), removing: try remove.map(Labels.label)))
            }
            guard let row = try await Labels.rows([id], runtime: runtime).first else { return }
            try options.emit(row) {
                let notYet = "Not labelled yet; `arrumatorcli review retry \(row.id)` reads it again."
                guard let labels = row.labels else { return "\(row.path)\n\(notYet)" }
                return row.path + "\n" + Terminal.labelTable(labels, indent: 2) + (row.labelled ? "" : "\n" + notYet)
            }
        }
    }

    struct Unlabelled: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read every document that has no labels yet with the model, such as one the model gave no answer for.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let runtime = try await options.runtime()
            _ = await runtime.lifecycle.ensureRunning()
            let ids = try await runtime.review.retryUnlabelled()
            await runtime.coordinator.drain()
            let rows = try await Labels.rows(ids, runtime: runtime)
            try options.emit(rows) {
                (rows.map { "#\($0.id) \($0.path)\n    \(Terminal.labels($0.labels, labelled: $0.labelled))" }
                    + ["Labelled \(rows.filter(\.labelled).count) of \(Format.count(rows.count, "document"))"])
                    .joined(separator: "\n")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Every label the archive's documents have, kind by kind, the most used first.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "Only labels of this kind.") var kind: LabelKind?

        func run() async throws {
            let runtime = try await options.runtime()
            let usage = try await runtime.services.labels.usage()
            let kinds = kind.map { [$0] } ?? LabelKind.allCases
            let listed = kinds.flatMap { usage[$0] ?? [] }
            try options.emit(listed) {
                listed.isEmpty ? "No labels yet." : Terminal.table(listed.map { [$0.label.kind.rawValue, Terminal.label($0.label),
                                                                                 Format.count($0.documents, "document")] })
            }
        }
    }

    struct Browse: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "The documents that have every label given, the newest by their own date first, and the labels they have, to narrow them down further by.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Labels, as kind=value, such as type=invoice sender=EDP; none lists every document and label.")
        var labels: [String] = []
        @Option(help: "List only the labels written with this in them, as the sidebar's filter does; the documents stay.")
        var matching = ""

        struct Scope: Encodable {
            var selection: [DocumentLabel]
            /// As the app lists them: the newest by their own date first, the undated last (`DocumentOrder.documentDate`).
            var documents: [Row]
            /// The labels the documents have, with how many of them have each, as the sidebar lists them: kind by kind,
            /// or all in one list, the most used first (`groupLabelsByKind`).
            var labels: [LabelUsage]
        }

        func validate() throws { _ = try labels.map(Labels.label) }

        func run() async throws {
            let runtime = try await options.runtime()
            let selection = try labels.map(Labels.label)
            let documents = try await runtime.services.documents.list(DocumentFilter(labels: selection), order: .documentDate,
                                                                      limit: Int.max)
            let usage = try await runtime.services.labels.usage(within: selection).matching(matching)
            let grouped = await runtime.settings.current.groupLabelsByKind
            let scope = Scope(selection: selection,
                              documents: documents.compactMap { d in d.id.map { Row(d, id: $0) } },
                              labels: usage.listed(groupedByKind: grouped))
            try options.emit(scope) {
                guard !scope.documents.isEmpty else { return "No document has every one of these labels." }
                return (scope.documents.map { "#\($0.id) \($0.path)\n    \(Terminal.labels($0.labels, labelled: $0.labelled))" }
                    + ["", Format.count(scope.documents.count, "document"), ""]
                    + [Terminal.table(scope.labels.map { [$0.label.kind.rawValue, Terminal.label($0.label),
                                                          Format.count($0.documents, "document")] })])
                    .joined(separator: "\n")
            }
        }
    }

    struct Similar: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Labels written so alike, or with the same digits grouped otherwise, that they may be one, each with the label a merge would keep, the most alike first.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let suggestions = try await options.runtime().services.labels.suggestions()
            try options.emit(suggestions) {
                suggestions.isEmpty ? "No labels look alike." : Terminal.table(suggestions.map {
                    [$0.kind.rawValue, "“\($0.value)”", "→ “\($0.into)”", String(format: "%.2f", $0.similarity),
                     $0.reason == .sameDigitsGroupedOtherwise ? "same digits, grouped otherwise" : ""]
                })
            }
        }
    }

    struct Merge: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Merge a label into another on every document, and in every reading from now on.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The label to merge, as kind=value, such as sender=\"EDP Comercial\".") var label: String
        @Option(help: "The label to keep, of the same kind, such as EDP.") var into: String

        func validate() throws { _ = try Labels.label(label) }

        func run() async throws {
            let outcome = try await options.runtime().labels.merge(try Labels.label(label), into: into)
            try options.emit(outcome) { Terminal.outcome(outcome) }
        }
    }

    struct Ignore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Take a label off every document, and never give it again.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The label, as kind=value, such as topic=document.") var label: String

        func validate() throws { _ = try Labels.label(label) }

        func run() async throws {
            let outcome = try await options.runtime().labels.ignore(try Labels.label(label))
            try options.emit(outcome) { Terminal.outcome(outcome) }
        }
    }

    struct KeepApart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "keep-apart", abstract: "Keep two alike labels apart: never merged, never offered to merge.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "One label, as kind=value, such as sender=EDP.") var label: String
        @Option(help: "The other label, of the same kind, such as EDF.") var from: String

        func validate() throws { _ = try Labels.label(label) }

        func run() async throws {
            let outcome = try await options.runtime().labels.keepApart(try Labels.label(label), from: from)
            try options.emit(outcome) { Terminal.outcome(outcome) }
        }
    }

    struct Rules: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "The rules about labels every reading follows, oldest first.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let rules = try await options.runtime().services.labels.rules()
            try options.emit(rules) {
                rules.isEmpty ? "No rules about labels yet." : Terminal.table(rules.map { ["#\($0.id ?? 0)", $0.summary] })
            }
        }
    }

    struct Forget: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Forget a rule about labels: readings from now on no longer follow it. Documents keep their labels.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The rule's number, as `labels rules` lists it.") var rule: Int64

        func run() async throws {
            let outcome = try await options.runtime().labels.forget(rule: rule)
            try options.emit(outcome) { "Forgot rule #\(rule): \(outcome.rule.summary)" }
        }
    }
}

extension LabelKind: ExpressibleByArgument {}
