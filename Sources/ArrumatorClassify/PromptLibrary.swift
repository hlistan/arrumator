import ArrumatorCore
import Foundation

public enum PromptError: Error, LocalizedError {
    case missingTemplate(String)
    case unfilledPlaceholders(template: String, names: [String])

    public var errorDescription: String? {
        switch self {
        case let .missingTemplate(n): "Prompt template \(n).md is missing from the bundle"
        case let .unfilledPlaceholders(t, names): "Prompt \(t) has unfilled placeholders: \(names.joined(separator: ", "))"
        }
    }
}

/// Loads prompt templates bundled as Markdown and fills `{{placeholders}}`.
public struct PromptLibrary: Sendable {
    private let templates: [String: String]

    public static func bundled() throws -> PromptLibrary {
        let names = ["organizing-principles", "field-rules", "file-name-rule", "classify-system", "classify-user", "repair-user",
                     "name-system", "name-user", "describe-folder-system", "describe-folder-user", "absorb-folder-system",
                     "absorb-folder-user"]
        var templates: [String: String] = [:]
        for name in names {
            guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts") else {
                throw PromptError.missingTemplate(name)
            }
            templates[name] = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return PromptLibrary(templates: templates)
    }

    public init(templates: [String: String]) { self.templates = templates }

    public func render(_ name: String, _ values: [String: String]) throws -> String {
        try Self.fill(try template(name), values, name: name)
    }

    /// The template as written, placeholders included.
    public func template(_ name: String) throws -> String {
        guard let text = templates[name] else { throw PromptError.missingTemplate(name) }
        return text
    }

    /// Fills `{{placeholders}}` in `text`; `name` identifies the text in the error when one is left unfilled.
    public static func fill(_ text: String, _ values: [String: String], name: String) throws -> String {
        var text = text
        for (key, value) in values { text = text.replacingOccurrences(of: "{{\(key)}}", with: value) }
        let leftovers = text.matches(of: /\{\{([a-z_]+)\}\}/).map { String($0.1) }
        guard leftovers.isEmpty else { throw PromptError.unfilledPlaceholders(template: name, names: leftovers) }
        return text
    }
}
