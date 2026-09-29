import CryptoKit
import Foundation
import Yams

public enum FrontMatterError: Error, LocalizedError {
    case missingFrontMatter(String)
    case invalidFrontMatter(String, String)

    public var errorDescription: String? {
        switch self {
        case let .missingFrontMatter(p): "\(p) has no YAML front matter"
        case let .invalidFrontMatter(p, why): "\(p) has invalid front matter: \(why)"
        }
    }
}

/// Markdown whose YAML front matter carries the data the app reads, followed by a body written for people. `_about.md`
/// and the record files are read and written the same way.
public enum FrontMatter {
    static let fence = "---"

    /// The YAML between the fences and the Markdown after them.
    public static func split(_ text: String, path: String) throws -> (yaml: String, body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix(fence + "\n") else { throw FrontMatterError.missingFrontMatter(path) }
        let afterOpen = normalized.dropFirst(fence.count + 1)
        guard let close = afterOpen.range(of: "\n\(fence)\n") ?? afterOpen.range(of: "\n\(fence)", options: .anchored.union(.backwards))
        else {
            throw FrontMatterError.missingFrontMatter(path)
        }
        return (String(afterOpen[afterOpen.startIndex..<close.lowerBound]), String(afterOpen[close.upperBound...]))
    }

    public static func encode(_ value: some Encodable) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options = YAMLEncoder.Options(indent: 2, width: -1, allowUnicode: true, sortKeys: false)
        return try encoder.encode(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from yaml: String, path: String) throws -> T {
        do {
            return try YAMLDecoder().decode(type, from: yaml)
        } catch {
            throw FrontMatterError.invalidFrontMatter(path, String(describing: error))
        }
    }

    public static func compose(_ value: some Encodable, body: String) throws -> String {
        "\(fence)\n" + (try encode(value)) + "\n\(fence)\n" + body
    }

    /// Reads a file's front matter as `T`.
    public static func read<T: Decodable>(_ type: T.Type, from text: String, path: String) throws -> (value: T, body: String) {
        let (yaml, body) = try split(text, path: path)
        return (try decode(type, from: yaml, path: path), body)
    }

    public static func sha256(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
