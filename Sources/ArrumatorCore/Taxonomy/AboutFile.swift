import CryptoKit
import Foundation
import Yams

/// Machine-maintained section of an `_about.md`, the only part the app rewrites in user-edited files.
/// It records what actually lives in the folder (from usage), which the model reads as extra context.
public struct LearnedBlock: Sendable, Codable, Hashable {
    public var examples: [String]
    public var correspondents: [String]
    public var updated: String?

    public init(examples: [String] = [], correspondents: [String] = [], updated: String? = nil) {
        self.examples = examples
        self.correspondents = correspondents
        self.updated = updated
    }

    public var isEmpty: Bool { examples.isEmpty && correspondents.isEmpty }
}

/// A folder's `_about.md`: YAML front matter + Markdown body + learned block.
public struct AboutFile: Sendable, Hashable {
    public static let schemaVersion = 1
    static let learnedBegin = "<!-- arrumator:learned-begin -->"
    static let learnedEnd = "<!-- arrumator:learned-end -->"
    static let examplesPrefix = "Recently filed here: "
    static let correspondentsPrefix = "Usual correspondents: "
    static let updatedPrefix = "Updated: "
    static let listSeparator = "; "

    public var definition: FolderDefinition
    /// Markdown body without the learned block.
    public var body: String
    public var learned: LearnedBlock

    public init(definition: FolderDefinition, body: String, learned: LearnedBlock = LearnedBlock()) {
        self.definition = definition
        self.body = body
        self.learned = learned
    }

    // MARK: Parsing

    public static func parse(_ text: String, path: String) throws -> AboutFile {
        let (definition, rest) = try FrontMatter.read(FolderDefinition.self, from: text, path: path)
        let (body, learned) = splitLearned(rest)
        return AboutFile(definition: definition, body: body, learned: learned)
    }

    static func splitLearned(_ text: String) -> (String, LearnedBlock) {
        guard let begin = text.range(of: learnedBegin), let end = text.range(of: learnedEnd, range: begin.upperBound..<text.endIndex) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), LearnedBlock())
        }
        let inner = text[begin.upperBound..<end.lowerBound]
        var block = LearnedBlock()
        for line in inner.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix(examplesPrefix) {
                block.examples = list(line.dropFirst(examplesPrefix.count))
            } else if line.hasPrefix(correspondentsPrefix) {
                block.correspondents = list(line.dropFirst(correspondentsPrefix.count))
            } else if line.hasPrefix(updatedPrefix) {
                block.updated = String(line.dropFirst(updatedPrefix.count))
            }
        }
        let body = (String(text[..<begin.lowerBound]) + String(text[end.upperBound...]))
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), block)
    }

    private static func list(_ s: Substring) -> [String] {
        s.components(separatedBy: listSeparator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Rendering

    public enum HashMode: Sendable {
        /// The app generated this content: stamp a fresh hash (file counts as pristine).
        case recompute
        /// Keep the stored hash, e.g. when only the learned block of a user-edited file changes.
        case preserve
    }

    /// Full file text.
    public func render(hash mode: HashMode) throws -> String {
        var def = definition
        def.schema = Self.schemaVersion
        if mode == .recompute {
            def.generatedHash = try Self.canonicalHash(definition: def, body: body)
        }
        return try Self.compose(definition: def, body: body, learned: learned)
    }

    /// SHA-256 over front matter (without `generated_hash`) and body (without learned block).
    public static func canonicalHash(definition: FolderDefinition, body: String) throws -> String {
        var def = definition
        def.generatedHash = nil
        def.schema = schemaVersion
        return FrontMatter.sha256(try frontMatterYAML(def) + "\n" + canonicalBody(body))
    }

    /// True when the file on disk still equals what the app generated (the user has not edited it).
    public var isPristine: Bool {
        guard let stored = definition.generatedHash, let hash = try? Self.canonicalHash(definition: definition, body: body) else {
            return false
        }
        return stored == hash
    }

    static func canonicalBody(_ body: String) -> String {
        body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func frontMatterYAML(_ def: FolderDefinition) throws -> String { try FrontMatter.encode(def) }

    static func compose(definition: FolderDefinition, body: String, learned: LearnedBlock) throws -> String {
        var out = try FrontMatter.compose(definition, body: canonicalBody(body) + "\n\n")
        out += learnedBegin + "\n"
        if !learned.examples.isEmpty { out += examplesPrefix + learned.examples.joined(separator: listSeparator) + "\n" }
        if !learned.correspondents.isEmpty {
            out += correspondentsPrefix + learned.correspondents.joined(separator: listSeparator) + "\n"
        }
        if let updated = learned.updated, !learned.isEmpty { out += updatedPrefix + updated + "\n" }
        out += learnedEnd + "\n"
        return out
    }
}
