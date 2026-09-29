import Foundation

/// Plain text from HTML without WebKit: scripts/styles removed, block elements become line breaks, tags dropped,
/// character references decoded.
enum HTMLText {
    static func strip(_ html: String) -> String {
        var text = html
        for (regex, replacement) in rewrites {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                  withTemplate: replacement)
        }
        return decodeEntities(text)
    }

    static func decodeEntities(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = ns.substring(with: match.range(at: 1))
            result += decode(body) ?? ns.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func decode(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if body.hasPrefix("#") {
            return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[body.lowercased()]
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "euro": "€",
        "copy": "©", "reg": "®", "laquo": "«", "raquo": "»", "ndash": "–", "mdash": "—", "hellip": "…",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "shy": "", "deg": "°", "ordm": "º", "ordf": "ª",
    ]

    private static let entity = regex(#"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});"#)

    private static let rewrites: [(NSRegularExpression, String)] = [
        (regex(#"<(script|style|head)\b[^>]*>[\s\S]*?</\1\s*>"#), ""),
        (regex(#"<!--[\s\S]*?-->"#), ""),
        (regex(#"<(br|/p|/div|/tr|/li|/h[1-6]|/table|/blockquote)\b[^>]*>"#), "\n"),
        (regex(#"</t[dh]\s*>"#), "\t"),
        (regex(#"<[^>]+>"#), ""),
        (regex(#"[ \t]+\n"#), "\n"),
        (regex(#"\n{3,}"#), "\n\n"),
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid HTML pattern \(pattern): \(error)")
        }
    }
}
