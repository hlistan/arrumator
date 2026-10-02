import CryptoKit
import Foundation
import Yams

public enum FrontMatterError: Error, LocalizedError {
    case missingFrontMatter(String)
    /// The front matter is not what the app reads, at the place given: a line and column of the file, or a field.
    case invalidFrontMatter(String, String)

    public var errorDescription: String? { "\(path): \(reason)" }

    var path: String {
        switch self {
        case let .missingFrontMatter(path), let .invalidFrontMatter(path, _): path
        }
    }

    /// Why, without the path, and without quoting the file: what it holds may be a model's answer or a document's text,
    /// which never goes into a log (AGENTS.md §4.1).
    var reason: String {
        switch self {
        case .missingFrontMatter: "it has no YAML front matter"
        case let .invalidFrontMatter(_, place): "its front matter cannot be read at \(place)"
        }
    }
}

/// Markdown whose YAML front matter carries the data the app reads, followed by a body written for people: every record
/// file of the archive is read and written this way.
public enum FrontMatter {
    static let fence = "---"
    /// The lines of a file before its YAML: the opening fence.
    static let linesBeforeYAML = 1

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

    /// Decodes `yaml`, the front matter of the file at `path`. YAML that does not parse, or does not hold `T`, throws
    /// `FrontMatterError.invalidFrontMatter` saying where, never what is there: Yams' own descriptions quote the line.
    /// What the type decoded throws, such as a format too new to read, passes as it is.
    public static func decode<T: Decodable>(_ type: T.Type, from yaml: String, path: String) throws -> T {
        do {
            return try YAMLDecoder().decode(type, from: yaml)
        } catch let DecodingError.dataCorrupted(context) where context.codingPath.isEmpty && context.underlyingError != nil {
            // Yams wraps every error that is not a decoding error, its parser's and the decoded type's own, this way.
            switch context.underlyingError {
            case let error as YamlError: throw FrontMatterError.invalidFrontMatter(path, place(of: error, in: yaml))
            case let error?: throw error
            case nil: throw FrontMatterError.invalidFrontMatter(path, place(of: DecodingError.dataCorrupted(context)))
            }
        } catch let error as YamlError {
            throw FrontMatterError.invalidFrontMatter(path, place(of: error, in: yaml))
        } catch let error as DecodingError {
            throw FrontMatterError.invalidFrontMatter(path, place(of: error))
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

    // MARK: Where front matter breaks

    /// The line and column of the file where the YAML could not be parsed.
    static func place(of error: YamlError, in yaml: String) -> String {
        switch error {
        case let .scanner(_, _, mark, _), let .parser(_, _, mark, _), let .composer(_, _, mark, _):
            return place(line: mark.line, column: mark.column)
        case let .duplicatedKeysInMapping(_, context):
            return place(line: context.mark.line, column: context.mark.column) + ", a key given twice"
        case let .reader(_, offset?, _, _):
            // A character YAML does not allow, by its byte in the YAML.
            let lines = yaml.utf8.prefix(offset).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            return place(line: lines.count, column: (lines.last?.count ?? 0) + 1)
        default:
            return "a place the YAML parser does not give"
        }
    }

    private static func place(line: Int, column: Int) -> String {
        "line \(line + linesBeforeYAML), column \(column)"
    }

    /// The field whose value is missing or not what the app reads: `entries[3].status`.
    static func place(of error: DecodingError) -> String {
        func field(_ path: [any CodingKey]) -> String {
            let field = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return field.isEmpty ? "its top" : String(field.drop { $0 == "." })
        }
        return switch error {
        case let .keyNotFound(key, context): "\(field(context.codingPath + [key])), which is missing"
        case let .valueNotFound(_, context): "\(field(context.codingPath)), which has no value"
        case let .typeMismatch(_, context): "\(field(context.codingPath)), which holds a value of another kind"
        case let .dataCorrupted(context): "\(field(context.codingPath)), which holds a value the app does not read"
        @unknown default: "a field the decoder does not name"
        }
    }
}
