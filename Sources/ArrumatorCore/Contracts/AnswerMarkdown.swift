import Foundation

/// An answer's Markdown, block by block, for the app to show as paragraphs, headings, lists, quotes and code rather than
/// the characters that mark them. Each block keeps its inline emphasis and code. The answer is untrusted, as a document
/// it read can tell the model what to write (OWASP, LLM05 Improper Output Handling), so nothing in it becomes active
/// where it is shown: a link becomes its words, followed by its address as plain text when the two differ, so a click
/// opens nothing and nothing is hidden; an image becomes its words (`inert`). A table is shown as its rows of plain text,
/// each column as wide as its widest cell, as code is (`table`): its cells are not paragraphs of their own.
public enum AnswerMarkdown {
    /// One block: its text, what it is, and how many lists it sits within beyond the first.
    public struct Block: Sendable, Hashable, Identifiable {
        public var id: Int
        public var text: AttributedString
        public var kind: Kind
        public var depth: Int
    }

    public enum Kind: Sendable, Hashable {
        case paragraph
        case heading(Int)
        /// A list item, with its marker: "•", or its number in an ordered list ("2."); "" for its second paragraph on.
        case item(marker: String)
        case quote
        case code
    }

    static let bullet = "•"

    /// The blocks of `markdown`, as far as it can be read: an answer still being written is shown as far as it came. Nil
    /// when nothing of it can be read as Markdown.
    public static func blocks(_ markdown: String) -> [Block]? {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let read = try? AttributedString(markdown: markdown, options: options) else { return nil }
        let parsed = inert(read)
        var blocks: [Block] = []
        var lastBlock: Int?
        var lastItem: Int?
        var table: Table?
        func endTable() {
            if let table { blocks.append(Block(id: blocks.count, text: AttributedString(table.text), kind: .code, depth: 0)) }
            table = nil
        }
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let piece = AttributedString(parsed[run.range])
            if let cell = Table.Cell(components) {
                if table?.id != cell.table { endTable() }
                table = table ?? Table(id: cell.table)
                table?.add(String(piece.characters), at: cell)
                lastBlock = nil
                continue
            }
            endTable()
            // The innermost component is the block the run belongs to.
            let identity = components.first?.identity
            if let identity, identity == lastBlock, !blocks.isEmpty {
                blocks[blocks.count - 1].text += piece
                continue
            }
            lastBlock = identity
            let item = components.first { if case .listItem = $0.kind { true } else { false } }
            var kind = Self.kind(components)
            if case .item = kind, let item, item.identity == lastItem { kind = .item(marker: "") }
            lastItem = item?.identity ?? lastItem
            let lists = components.filter { [.orderedList, .unorderedList].contains($0.kind) }.count
            blocks.append(Block(id: blocks.count, text: piece, kind: kind, depth: max(0, lists - 1)))
        }
        endTable()
        // Code ends with the line break that closes its last line, which would show as an empty line.
        for index in blocks.indices where blocks[index].kind == .code {
            while blocks[index].text.characters.last?.isNewline == true {
                blocks[index].text.removeSubrange(blocks[index].text.index(beforeCharacter: blocks[index].text.endIndex)..<blocks[index].text.endIndex)
            }
        }
        return blocks
    }

    /// `text` with nothing that acts when shown: each link becomes its words, and its address in parentheses after them
    /// when the two differ, as plain text in the link's block and emphasis; each image becomes its words. A link written
    /// across runs of different emphasis is one range of `runs[\.link]`, so its address is written once.
    static func inert(_ text: AttributedString) -> AttributedString {
        var shown = AttributedString()
        for (link, range) in text.runs[\.link] {
            var words = AttributedString(text[range])
            words.link = nil
            words.imageURL = nil
            let said = String(words.characters)
            shown += words
            if let address = link?.absoluteString, address != said {
                let attributes = words.runs.last?.attributes ?? AttributeContainer()
                shown += AttributedString(" (\(address))", attributes: attributes)
            }
        }
        return shown
    }

    /// A table as it is read, row by row, its cells' words in plain text.
    struct Table {
        let id: Int
        private var rows: [(id: Int, header: Bool, cells: [Int: String])] = []

        init(id: Int) { self.id = id }

        /// Where a run sits in a table: which table, which row, which column, and whether the row heads it; nil for a run
        /// outside any table.
        struct Cell {
            let table: Int
            let row: Int
            let header: Bool
            let column: Int

            init?(_ components: [PresentationIntent.IntentType]) {
                var table: Int?, row: (Int, Bool)?, column: Int?
                for component in components {
                    switch component.kind {
                    case .table: table = component.identity
                    case .tableHeaderRow: row = (component.identity, true)
                    case .tableRow: row = (component.identity, false)
                    case let .tableCell(index): column = index
                    default: continue
                    }
                }
                guard let table, let row, let column else { return nil }
                (self.table, self.row, header, self.column) = (table, row.0, row.1, column)
            }
        }

        mutating func add(_ words: String, at cell: Cell) {
            if rows.last?.id != cell.row { rows.append((cell.row, cell.header, [:])) }
            rows[rows.count - 1].cells[cell.column, default: ""] += words
        }

        /// The rows, each column as wide as its widest cell and the columns `gap` apart, a line of dashes under the
        /// heading row; a cell's line breaks become spaces.
        var text: String {
            let lines = rows.map { row in
                (header: row.header, cells: (0..<((row.cells.keys.max() ?? -1) + 1)).map { column in
                    (row.cells[column] ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                })
            }
            let columns = lines.map(\.cells.count).max() ?? 0
            let widths = (0..<columns).map { column in lines.map { $0.cells.indices.contains(column) ? $0.cells[column].count : 0 }.max() ?? 0 }
            func line(_ cells: [String]) -> String {
                cells.enumerated().map { column, words in
                    column == cells.count - 1 ? words : words.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                }.joined(separator: Self.gap)
            }
            return lines.flatMap { row in
                row.header ? [line(row.cells), line(widths.map { String(repeating: Self.rule, count: $0) })] : [line(row.cells)]
            }.joined(separator: "\n")
        }

        static let gap = "  "
        static let rule = "-"
    }

    /// What a block is, from the components of its intent, innermost first.
    private static func kind(_ components: [PresentationIntent.IntentType]) -> Kind {
        for (index, component) in components.enumerated() {
            switch component.kind {
            case let .header(level): return .heading(level)
            case .codeBlock: return .code
            case .blockQuote: return .quote
            case let .listItem(ordinal):
                let ordered = components.dropFirst(index + 1).first { [.orderedList, .unorderedList].contains($0.kind) }?.kind == .orderedList
                return .item(marker: ordered ? "\(ordinal)." : bullet)
            default: continue
            }
        }
        return .paragraph
    }
}
