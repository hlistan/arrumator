import Foundation

/// A parsed RFC 5322 / MIME entity. The raw message is held as an ISO-8859-1 string, a lossless byte-for-byte
/// view, so 8-bit bodies can be turned back into bytes and decoded with the declared charset.
struct MIMEPart {
    var headers: [(name: String, value: String)]
    var body: Substring
    var children: [MIMEPart]

    /// Parses `data` as a message, following multipart nesting up to `maxDepth` levels.
    static func parse(_ data: Data, maxDepth: Int) -> MIMEPart {
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n")
        return parse(unified[...], depth: 0, maxDepth: maxDepth)
    }

    /// The first header with this name, unfolded but not decoded.
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Header value with RFC 2047 encoded words and raw UTF-8 decoded.
    func decodedHeader(_ name: String) -> String? {
        header(name).map(HeaderDecoding.decode)
    }

    var mediaType: String {
        HeaderDecoding.parameters(header("Content-Type") ?? "text/plain").value.lowercased()
    }

    var contentTypeParameters: [String: String] {
        HeaderDecoding.parameters(header("Content-Type") ?? "").parameters
    }

    /// A part sent as an attachment: so disposed, or with a name and no disposition. One disposed inline is shown in the
    /// body, whatever its name (RFC 2183 §2.1), and is still listed among the attachments when it is not the body.
    var isAttachment: Bool {
        switch HeaderDecoding.parameters(header("Content-Disposition") ?? "").value.lowercased() {
        case "attachment": true
        case "inline": false
        default: filename != nil
        }
    }

    /// Attachment filename from `Content-Disposition` or the `name` parameter of `Content-Type`.
    var filename: String? {
        let disposition = HeaderDecoding.parameters(header("Content-Disposition") ?? "").parameters
        guard let name = disposition["filename"] ?? contentTypeParameters["name"], !name.isEmpty else { return nil }
        return HeaderDecoding.decode(name)
    }

    /// Body bytes after undoing the transfer encoding, at most `cap` of them, and whether there were more.
    func decodedBody(cap: Int) -> (bytes: Data, truncated: Bool) {
        let encoding = (header("Content-Transfer-Encoding") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let bytes: Data = switch encoding {
        case "base64":
            Data(base64Encoded: String(body.filter { !$0.isWhitespace }), options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            HeaderDecoding.quotedPrintable(String(body), underscoreIsSpace: false)
        default:
            Data(body.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        }
        return bytes.count > cap ? (bytes.prefix(cap), true) : (bytes, false)
    }

    /// Body as text in the declared charset (UTF-8, then Latin-1 when undeclared or unknown), from at most `cap` bytes,
    /// and whether there were more. A character the cap cuts in two is left out, so a cut body stays in its own charset.
    func decodedText(cap: Int) -> (text: String, truncated: Bool) {
        let (bytes, truncated) = decodedBody(cap: cap)
        if let charset = contentTypeParameters["charset"], let encoding = HeaderDecoding.encoding(ianaName: charset),
           let text = TextEncodingDetector.decode(bytes, as: encoding, allowCutTail: truncated) {
            return (text, truncated)
        }
        let text = TextEncodingDetector.strictUTF8(bytes, allowCutTail: truncated)
            ?? String(data: bytes, encoding: .isoLatin1) ?? ""
        return (text, truncated)
    }

    /// All leaf parts, depth first. A message within the message (`message/rfc822`, one forwarded as an attachment) is
    /// one leaf: its body is not the message's, nor are its attachments (`attachedMessage`).
    var leaves: [MIMEPart] {
        children.isEmpty ? [self] : children.flatMap(\.leaves)
    }

    /// Whether this part is a message of its own, attached to the one it is part of.
    var isMessage: Bool { mediaType == "message/rfc822" }

    /// The message this part holds, read from at most `cap` of its bytes, when it is one (`isMessage`).
    func attachedMessage(cap: Int, maxDepth: Int) -> MIMEPart? {
        isMessage ? Self.parse(decodedBody(cap: cap).bytes, maxDepth: maxDepth) : nil
    }

    // MARK: Parsing

    private static func parse(_ text: Substring, depth: Int, maxDepth: Int) -> MIMEPart {
        let headerEnd = text.range(of: "\n\n")
        let headerBlock = headerEnd.map { text[..<$0.lowerBound] } ?? text
        let body = headerEnd.map { text[$0.upperBound...] } ?? text[text.endIndex...]
        var part = MIMEPart(headers: parseHeaders(headerBlock), body: body, children: [])
        guard depth < maxDepth else { return part }
        if part.mediaType.hasPrefix("multipart/"), let boundary = part.contentTypeParameters["boundary"], !boundary.isEmpty {
            part.children = splitMultipart(body, boundary: boundary).map { parse($0, depth: depth + 1, maxDepth: maxDepth) }
        }
        return part
    }

    private static func parseHeaders(_ block: Substring) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { headers.append((name, value)) }
            }
        }
        return headers
    }

    private static func splitMultipart(_ body: Substring, boundary: String) -> [Substring] {
        let delimiter = "--" + boundary
        var starts: [Range<Substring.Index>] = []
        var searchFrom = body.startIndex
        while let found = body.range(of: delimiter, range: searchFrom..<body.endIndex) {
            if found.lowerBound == body.startIndex || body[body.index(before: found.lowerBound)] == "\n" {
                starts.append(found)
            }
            searchFrom = found.upperBound
        }
        var parts: [Substring] = []
        for (index, delimiterRange) in starts.enumerated() {
            let rest = body[delimiterRange.upperBound...]
            if rest.hasPrefix("--") { break }
            guard let lineEnd = rest.firstIndex(of: "\n") else { break }
            let contentStart = body.index(after: lineEnd)
            let contentEnd = index + 1 < starts.count ? starts[index + 1].lowerBound : body.endIndex
            guard contentStart <= contentEnd else { continue }
            var content = body[contentStart..<contentEnd]
            if content.hasSuffix("\n") { content = content.dropLast() }
            parts.append(content)
        }
        return parts
    }
}

/// RFC 2047 encoded words, RFC 2231 parameters, quoted-printable and charset lookup.
enum HeaderDecoding {
    /// Decodes raw 8-bit UTF-8 and `=?charset?B|Q?…?=` encoded words; whitespace between adjacent encoded words
    /// is dropped as the RFC requires.
    static func decode(_ raw: String) -> String {
        let latin1Bytes = Data(raw.unicodeScalars.compactMap { $0.value < 256 ? UInt8($0.value) : nil })
        let text = latin1Bytes.count == raw.unicodeScalars.count
            ? (String(validating: latin1Bytes, as: UTF8.self) ?? raw) : raw
        let ns = text as NSString
        var result = ""
        var cursor = 0
        var previousWasEncoded = false
        for match in encodedWord.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(previousWasEncoded && gap.allSatisfy(\.isWhitespace)) { result += gap }
            let charset = ns.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? ""
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            let bytes = mode == "B"
                ? Data(base64Encoded: payload.paddedBase64, options: .ignoreUnknownCharacters) ?? Data()
                : quotedPrintable(payload, underscoreIsSpace: true)
            if let encoding = encoding(ianaName: charset), let decoded = String(data: bytes, encoding: encoding) {
                result += decoded
                previousWasEncoded = true
            } else {
                result += ns.substring(with: match.range)
                previousWasEncoded = false
            }
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Splits `type/subtype; a=b; c="d"` into the main value and lowercased parameters, joining RFC 2231
    /// continuations (`name*0=`, `name*1=`) and decoding extended values (`name*=utf-8''%D0%9F`).
    static func parameters(_ header: String) -> (value: String, parameters: [String: String]) {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for char in header {
            if char == "\"" { quoted.toggle() }
            if char == ";", !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        let value = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var simple: [String: String] = [:]
        var segments: [String: [(index: Int, value: String, extended: Bool)]] = [:]
        for field in fields.dropFirst() {
            guard let equals = field.firstIndex(of: "=") else { continue }
            var key = field[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = field[field.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
            let extended = key.hasSuffix("*")
            if extended { key.removeLast() }
            if let star = key.firstIndex(of: "*"), let index = Int(key[key.index(after: star)...]) {
                segments[String(key[..<star]), default: []].append((index, raw, extended))
            } else if extended {
                segments[key, default: []].append((0, raw, true))
            } else {
                simple[key] = raw
            }
        }
        for (key, parts) in segments {
            let ordered = parts.sorted { $0.index < $1.index }
            var charset = "utf-8"
            var bytes = Data()
            for (position, part) in ordered.enumerated() {
                var piece = part.value
                if part.extended, position == 0 {
                    let pieces = piece.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if pieces.count == 3 {
                        charset = pieces[0].isEmpty ? charset : String(pieces[0])
                        piece = String(pieces[2])
                    }
                }
                bytes.append(part.extended ? percentDecoded(piece) : Data(piece.utf8))
            }
            let encoding = encoding(ianaName: charset) ?? .utf8
            simple[key] = String(data: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
        }
        return (value, simple)
    }

    static func quotedPrintable(_ text: String, underscoreIsSpace: Bool) -> Data {
        var bytes = Data()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "=" {
                if index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    index += 2
                    continue
                }
                if index + 2 < scalars.count,
                   let byte = UInt8(String(String.UnicodeScalarView(scalars[(index + 1)...(index + 2)])), radix: 16) {
                    bytes.append(byte)
                    index += 3
                    continue
                }
            }
            bytes.append(underscoreIsSpace && scalar == "_" ? 0x20 : UInt8(truncatingIfNeeded: scalar.value))
            index += 1
        }
        return bytes
    }

    static func encoding(ianaName: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(ianaName.trimmingCharacters(in: .whitespaces) as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static func percentDecoded(_ text: String) -> Data {
        var bytes = Data()
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) {
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return bytes
    }

    private static let encodedWord: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?]*)\?="#)
        } catch {
            preconditionFailure("Invalid encoded-word pattern: \(error)")
        }
    }()
}

private extension String {
    /// Base64 with the `=` padding some mailers omit.
    var paddedBase64: String {
        let remainder = count % 4
        return remainder == 0 ? self : self + String(repeating: "=", count: 4 - remainder)
    }
}
