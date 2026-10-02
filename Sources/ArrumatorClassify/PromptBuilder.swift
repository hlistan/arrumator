import ArrumatorCore
import Foundation

/// Renders the prompt the model reads a document with. It is the app's own, written for labelling: the model picks
/// out the document's signals, which become its labels, and names its file.
public struct PromptBuilder: Sendable {
    public let library: PromptTemplates
    public let config: AnalysisConfig
    public let labels: LabelsConfig
    public let naming: NamingConfig

    public init(library: PromptTemplates, config: AnalysisConfig, labels: LabelsConfig, naming: NamingConfig) {
        self.library = library
        self.config = config
        self.labels = labels
        self.naming = naming
    }

    public func analysisSystem() throws -> String {
        try library.render("labels-system", ["max_per_kind": String(labels.maxPerKind), "max_name_chars": String(naming.maxChars)])
    }

    /// The document, with what the extractor found in it, after what the archive's labels say, when they say anything.
    public func analysisUser(content: ExtractedContent, guidance: LabelGuidance) throws -> String {
        try library.render("document-user", ["archive": try archiveBlock(guidance), "document": documentBlock(content)])
    }

    /// The labels the archive uses, by the answer's name for their kind, the user's merges and the labels the user does
    /// not want, one per line; empty for an archive without any.
    func archiveBlock(_ guidance: LabelGuidance) throws -> String {
        guard !guidance.isEmpty else { return "" }
        let key = ClassificationSchema.labelsKey
        let used = ClassificationSchema.answerOrder.compactMap { kind in
            guidance.used[kind].flatMap { $0.isEmpty ? nil : "- \(key(kind)): " + $0.joined(separator: "; ") }
        }
        let preferred = guidance.preferred.map { "- \(key($0.from.kind)): \($0.from.value) → \($0.to)" }
        let unwanted = guidance.unwanted.map { "- \(key($0.kind)): \($0.value)" }
        func lines(_ items: [String]) -> String { items.isEmpty ? Self.noLines : items.joined(separator: "\n") }
        return try library.render("archive-labels", ["used": lines(used), "preferred": lines(preferred), "unwanted": lines(unwanted)])
            + "\n\n"
    }

    /// What an empty list of the archive's labels reads as.
    static let noLines = "-"

    public func repair(errors: String) throws -> String {
        try library.render("repair-user", ["errors": errors])
    }

    func documentBlock(_ c: ExtractedContent) -> String {
        var lines = ["Original file name: \(c.source.originalFilename)"]
        var format = "Format: \(c.source.fileExtension.isEmpty ? c.kind.rawValue : c.source.fileExtension.uppercased())"
        if let pages = c.pageCount { format += ", \(pages) pages" }
        // The model reads the language itself: the detector's guess misleads it on mixed pages, such as an English
        // invoice sent to a Portuguese address.
        format += ", \(c.textOrigin.rawValue)"
        lines.append(format)
        let dates = c.entities.dates.prefix(config.promptDatesLimit).map(\.date)
        if !dates.isEmpty { lines.append("DETECTED DATES: " + dates.joined(separator: ", ")) }
        let ids = c.entities.stableKeys.prefix(config.promptIdentifiersLimit).map { "\($0.kind.described) \($0.value)" }
        if !ids.isEmpty { lines.append("IDENTIFIERS: " + ids.joined(separator: "; ")) }
        if let from = c.metadata[MetadataKey.emailFrom] { lines.append("E-MAIL FROM: \(from)") }
        if let subject = c.metadata[MetadataKey.emailSubject] { lines.append("E-MAIL SUBJECT: \(subject)") }
        if let v = c.visual {
            lines.append("VISUAL: kind=\(v.imageKind.rawValue); \(v.description)"
                + (v.organisations.isEmpty ? "" : "; organisations: \(v.organisations.joined(separator: ", "))"))
        }
        if !c.warnings.isEmpty { lines.append("NOTES: " + c.warnings.map(\.code.rawValue).joined(separator: ", ")) }
        let excerpt = c.classificationExcerpt(maxChars: config.excerptChars, tailDivisor: config.excerptTailDivisor)
        lines.append("--- TEXT (excerpt, \(excerpt.count) of \(c.text.count) chars) ---")
        lines.append(excerpt.isEmpty ? "(no text could be extracted)" : excerpt)
        lines.append("--- END ---")
        return lines.joined(separator: "\n")
    }
}
