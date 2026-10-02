import Foundation

/// An answer's Markdown, block by block, for the app to show as paragraphs, headings, lists, quotes and code rather than
/// the characters that mark them. Each block keeps its inline emphasis, links and code.
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
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return nil }
        var blocks: [Block] = []
        var lastBlock: Int?
        var lastItem: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            // The innermost component is the block the run belongs to.
            let identity = components.first?.identity
            let piece = AttributedString(parsed[run.range])
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
        // Code ends with the line break that closes its last line, which would show as an empty line.
        for index in blocks.indices where blocks[index].kind == .code {
            while blocks[index].text.characters.last?.isNewline == true {
                blocks[index].text.removeSubrange(blocks[index].text.index(beforeCharacter: blocks[index].text.endIndex)..<blocks[index].text.endIndex)
            }
        }
        return blocks
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
