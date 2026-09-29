import ArrumatorCore
import Foundation

/// Renders the prompt the model reads a document with. It is the app's own, written for labelling: the model picks
/// out the document's signals, says what the document is, and names its file.
public struct PromptBuilder: Sendable {
    public let library: PromptLibrary
    public let config: AnalysisConfig
    public let labels: LabelsConfig
    public let naming: NamingConfig

    public init(library: PromptLibrary, config: AnalysisConfig, labels: LabelsConfig, naming: NamingConfig) {
        self.library = library
        self.config = config
        self.labels = labels
        self.naming = naming
    }

    public func analysisSystem() throws -> String {
        try library.render("labels-system", ["max_per_kind": String(labels.maxPerKind), "max_name_chars": String(naming.maxChars)])
    }

    /// The document, with the senders the app recognised in it, so it is named as their earlier documents were.
    public func analysisUser(content: ExtractedContent, correspondents: [CorrespondentMatch]) throws -> String {
        try library.render("document-user", ["document": documentBlock(content, correspondents: correspondents)])
    }

    public func repair(errors: String) throws -> String {
        try library.render("repair-user", ["errors": errors])
    }

    func documentBlock(_ c: ExtractedContent, correspondents: [CorrespondentMatch]) -> String {
        var lines = ["Original file name: \(c.source.originalFilename)"]
        var format = "Format: \(c.source.fileExtension.isEmpty ? c.kind.rawValue : c.source.fileExtension.uppercased())"
        if let pages = c.pageCount { format += ", \(pages) pages" }
        format += ", \(c.textOrigin.rawValue), language \(c.language.primary) (\(String(format: "%.2f", c.language.confidence)))"
        lines.append(format)
        let dates = c.entities.dates.prefix(config.promptDatesLimit).map(\.date)
        if !dates.isEmpty { lines.append("DETECTED DATES: " + dates.joined(separator: ", ")) }
        let ids = c.entities.stableKeys.prefix(config.promptIdentifiersLimit).map { "\($0.kind.rawValue) \($0.value)" }
        if !ids.isEmpty { lines.append("IDENTIFIERS: " + ids.joined(separator: "; ")) }
        if !correspondents.isEmpty {
            lines.append("KNOWN CORRESPONDENTS FOUND: " + correspondents.prefix(3)
                .map { "\($0.correspondent.canonicalName) (by \($0.matchedBy.rawValue))" }.joined(separator: "; "))
        }
        if let from = c.metadata["email:from"] { lines.append("E-MAIL FROM: \(from)") }
        if let subject = c.metadata["email:subject"] { lines.append("E-MAIL SUBJECT: \(subject)") }
        if let v = c.visual {
            lines.append("VISUAL: kind=\(v.imageKind); \(v.description)"
                + (v.organisations.isEmpty ? "" : "; organisations: \(v.organisations.joined(separator: ", "))"))
        }
        if !c.warnings.isEmpty { lines.append("NOTES: " + c.warnings.map(\.code.rawValue).joined(separator: ", ")) }
        let excerpt = c.classificationExcerpt(maxChars: config.excerptChars)
        lines.append("--- TEXT (excerpt, \(excerpt.count) of \(c.text.count) chars) ---")
        lines.append(excerpt.isEmpty ? "(no text could be extracted)" : excerpt)
        lines.append("--- END ---")
        return lines.joined(separator: "\n")
    }
}
