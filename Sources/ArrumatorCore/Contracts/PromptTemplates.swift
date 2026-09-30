import Foundation

public enum PromptError: Error, LocalizedError, Equatable {
    case missingTemplate(String)
    case unfilledPlaceholders(template: String, names: [String])
    /// Values given for placeholders the template does not have: the code and the template disagree.
    case unusedValues(template: String, names: [String])

    public var errorDescription: String? {
        switch self {
        case let .missingTemplate(n): "Prompt template \(n).md is missing from the bundle"
        case let .unfilledPlaceholders(t, names): "Prompt \(t) has unfilled placeholders: \(names.joined(separator: ", "))"
        case let .unusedValues(t, names): "Prompt \(t) has no placeholders for: \(names.joined(separator: ", "))"
        }
    }
}

/// Prompt templates, bundled as Markdown in a module's `Prompts` folder, with `{{placeholders}}` the code fills. What a
/// model is told is data (AGENTS.md §3), so every module that asks a model keeps its wording here, never in Swift.
public struct PromptTemplates: Sendable {
    private let templates: [String: String]

    /// The folder of a module's resources holding its prompt templates.
    public static let subdirectory = "Prompts"
    public static let fileExtension = "md"

    public init(templates: [String: String]) { self.templates = templates }

    /// Loads `names` from `bundle`'s `Prompts` folder.
    public static func bundled(_ names: [String], in bundle: Bundle) throws -> PromptTemplates {
        var templates: [String: String] = [:]
        for name in names {
            guard let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory) else {
                throw PromptError.missingTemplate(name)
            }
            templates[name] = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return PromptTemplates(templates: templates)
    }

    public func render(_ name: String, _ values: [String: String]) throws -> String {
        try Self.fill(try template(name), values, name: name)
    }

    /// The template as written, placeholders included.
    public func template(_ name: String) throws -> String {
        guard let text = templates[name] else { throw PromptError.missingTemplate(name) }
        return text
    }

    /// Fills the `{{placeholders}}` of `template` in one pass over the template alone: a value is inserted as it is and
    /// never read again, so text that quotes a placeholder, such as a document with an unrendered merge field, stays
    /// as written. Every placeholder needs a value and every value a placeholder; `name` identifies the template in
    /// the error.
    public static func fill(_ template: String, _ values: [String: String], name: String) throws -> String {
        let placeholders = template.matches(of: /\{\{([a-z_]+)\}\}/)
        let named = Set(placeholders.map { String($0.1) })
        let unfilled = named.subtracting(values.keys)
        guard unfilled.isEmpty else { throw PromptError.unfilledPlaceholders(template: name, names: unfilled.sorted()) }
        let unused = Set(values.keys).subtracting(named)
        guard unused.isEmpty else { throw PromptError.unusedValues(template: name, names: unused.sorted()) }
        var filled = ""
        var rest = template.startIndex
        for placeholder in placeholders {
            filled += template[rest..<placeholder.range.lowerBound]
            filled += values[String(placeholder.1), default: ""]
            rest = placeholder.range.upperBound
        }
        return filled + template[rest...]
    }
}

/// What a model answered, narrowed to the JSON object it was asked for. Under constrained decoding the answer is that
/// object alone; a model that thinks aloud may still put its reasoning, between `<think>` tags, around it.
public enum ModelOutput {
    public static func jsonObject(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end { t = String(t[start...end]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
