import Foundation

/// Plain text from HTML without WebKit: scripts, style sheets, the head and comments removed with what they hold, the
/// ends of lines and blocks become line breaks and the ends of cells tabs, other tags dropped, and character
/// references decoded: numeric ones, and every name HTML has (`HTMLEntities`).
///
/// Markup is removed in one pass over the UTF-8 bytes that is linear in the input whatever is left unclosed
/// (CWE-1333): a search for what closes a construct either moves the pass past what it found or, finding nothing, is
/// never made again, since the pass only moves forward. Every cut falls on an ASCII byte, so the text between is copied
/// whole.
enum HTMLText {
    static func strip(_ html: String, entities: HTMLEntities) -> String {
        var markup = Markup(Array(html.utf8))
        return decodeEntities(String(decoding: tidyWhitespace(markup.text()), as: UTF8.self), entities: entities)
    }

    /// `text` with each character reference replaced by what it stands for; one that stands for nothing, such as a
    /// name HTML does not have, is left as written.
    static func decodeEntities(_ text: String, entities: HTMLEntities) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in reference.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = ns.substring(with: match.range(at: 1))
            result += decode(body, entities: entities) ?? ns.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func decode(_ body: String, entities: HTMLEntities) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if body.hasPrefix("#") {
            return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return entities.character(named: body)
    }

    /// `&`, a decimal or hexadecimal number or a name, and `;`. Names are letters and digits, at most 31 of them, the
    /// longest HTML has; every part is bounded, so matching is linear.
    private static let reference: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,30});"#)
        } catch {
            preconditionFailure("Invalid character reference pattern: \(error)")
        }
    }()

    /// Spaces and tabs before a line break removed, and more than one blank line made one.
    private static func tidyWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var spaces: [UInt8] = []
        var lineBreaks = 0
        for byte in bytes {
            switch byte {
            case ASCII.space, ASCII.tab:
                spaces.append(byte)
            case ASCII.lineFeed:
                spaces.removeAll(keepingCapacity: true)
                lineBreaks += 1
                if lineBreaks <= maxLineBreaks { output.append(byte) }
            default:
                output += spaces
                spaces.removeAll(keepingCapacity: true)
                lineBreaks = 0
                output.append(byte)
            }
        }
        return output + spaces
    }

    /// Line breaks kept in a row: one blank line.
    private static let maxLineBreaks = 2
}

/// The bytes of HTML syntax.
private enum ASCII {
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let comment = Array("<!--".utf8)
    static let commentEnd = Array("-->".utf8)
    static let endTag = Array("</".utf8)

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == lineFeed || (0x0B...0x0D).contains(byte)
    }

    /// A byte of a word, as a regular expression's `\b` sees it: a letter or digit of any script, or `_`.
    static func isWord(_ byte: UInt8) -> Bool {
        byte >= 0x80 || byte == UInt8(ascii: "_") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lowercased(byte))
    }

    /// `byte` with an ASCII capital letter made small; every other byte as it is.
    static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + (UInt8(ascii: "a") - UInt8(ascii: "A")) : byte
    }
}

/// Removes markup from HTML's bytes in one forward pass.
private struct Markup {
    private let bytes: [UInt8]
    private var output: [UInt8] = []
    // What a search found none of from where it started, and so none of after: never looked for again.
    private var noTagEnd = false
    private var noCommentEnd = false
    private var noEndTag: Set<[UInt8]> = []

    /// Elements removed with everything in them.
    private static let hidden = ["script", "style", "head"].map { Array($0.utf8) }
    /// Tags that end a line: a line break, and the ends of paragraphs, blocks, rows, items, headings and tables.
    private static let lineEnds = ["br", "/p", "/div", "/tr", "/li", "/h1", "/h2", "/h3", "/h4", "/h5", "/h6", "/table",
                                   "/blockquote"].map { Array($0.utf8) }
    /// Tags that end a table cell.
    private static let cellEnds = ["/td", "/th"].map { Array($0.utf8) }

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func text() -> [UInt8] {
        output.reserveCapacity(bytes.count)
        var position = 0
        while position < bytes.count {
            if bytes[position] == ASCII.lessThan, let next = markup(at: position) {
                position = next
            } else {
                output.append(bytes[position])
                position += 1
            }
        }
        return output
    }

    /// Removes the markup that starts with the `<` at `start`, adding what stands for it, and returns where the text
    /// goes on; `nil` when the `<` starts no markup and is text.
    private mutating func markup(at start: Int) -> Int? {
        // Every construct ends in a `>`: once none is left, every `<` is text.
        guard !noTagEnd else { return nil }
        let name = start + 1
        if hasPrefix(ASCII.comment, at: start), let end = commentEnd(from: start + ASCII.comment.count) {
            return end
        }
        if let element = Self.hidden.first(where: { isTagName($0, at: name) }),
           let tagEnd = tagEnd(from: name + element.count), let end = endTag(element, from: tagEnd + 1) {
            return end
        }
        if let lineEnd = Self.lineEnds.first(where: { isTagName($0, at: name) }),
           let tagEnd = tagEnd(from: name + lineEnd.count) {
            output.append(ASCII.lineFeed)
            return tagEnd + 1
        }
        if let cellEnd = Self.cellEnds.first(where: { hasPrefix($0, at: name, ignoringCase: true) }),
           let end = closingBracket(after: name + cellEnd.count) {
            output.append(ASCII.tab)
            return end
        }
        // Any other tag: a `<`, at least one byte, and the next `>`.
        guard let tagEnd = tagEnd(from: name), tagEnd > name else { return nil }
        return tagEnd + 1
    }

    /// Whether `name` is written at `index`, in any case, and ends there as a word does.
    private func isTagName(_ name: [UInt8], at index: Int) -> Bool {
        hasPrefix(name, at: index, ignoringCase: true)
            && (index + name.count == bytes.count || !ASCII.isWord(bytes[index + name.count]))
    }

    private func hasPrefix(_ prefix: [UInt8], at index: Int, ignoringCase: Bool = false) -> Bool {
        guard index + prefix.count <= bytes.count else { return false }
        for (offset, byte) in prefix.enumerated() {
            let found = bytes[index + offset]
            guard found == byte || (ignoringCase && ASCII.lowercased(found) == byte) else { return false }
        }
        return true
    }

    /// The index after optional whitespace and a `>` that follow `index`, or `nil`.
    private func closingBracket(after index: Int) -> Int? {
        var index = index
        while index < bytes.count, ASCII.isWhitespace(bytes[index]) { index += 1 }
        return index < bytes.count && bytes[index] == ASCII.greaterThan ? index + 1 : nil
    }

    /// The index of the first `>` from `index`.
    private mutating func tagEnd(from index: Int) -> Int? {
        guard !noTagEnd else { return nil }
        if let found = bytes[index...].firstIndex(of: ASCII.greaterThan) { return found }
        noTagEnd = true
        return nil
    }

    /// The index after the first `-->` from `index`.
    private mutating func commentEnd(from index: Int) -> Int? {
        guard !noCommentEnd else { return nil }
        if let found = firstIndex(of: ASCII.commentEnd, from: index) { return found + ASCII.commentEnd.count }
        noCommentEnd = true
        return nil
    }

    /// The index after the first end tag of `element` from `index`: `</`, the name in any case, whitespace and `>`.
    private mutating func endTag(_ element: [UInt8], from index: Int) -> Int? {
        guard !noEndTag.contains(element) else { return nil }
        var index = index
        while let found = firstIndex(of: ASCII.endTag, from: index) {
            let name = found + ASCII.endTag.count
            if hasPrefix(element, at: name, ignoringCase: true), let end = closingBracket(after: name + element.count) {
                return end
            }
            index = name
        }
        noEndTag.insert(element)
        return nil
    }

    private func firstIndex(of token: [UInt8], from index: Int) -> Int? {
        var index = index
        while index + token.count <= bytes.count, let found = bytes[index...].firstIndex(of: token[0]) {
            if hasPrefix(token, at: found) { return found }
            index = found + 1
        }
        return nil
    }
}
