import ArrumatorCore
import Foundation

/// Renders the prompts that place and name a document. The path is decided from the archive's logic and the document
/// alone: shown folders, any at all, a model copies them whether they fit or not (an older arrangement's, another
/// sender's that looks alike, one broad area for everything). The app maps the path onto the tree itself, resolving each
/// level by identity (`PlacementGuard`), and asks the model only narrow questions: which of the few folders beside a
/// decided one, if any, it is (`judgeUser`).
public struct PromptBuilder: Sendable {
    public let library: PromptLibrary
    public let config: ClassificationConfig
    public let naming: NamingConfig

    public init(library: PromptLibrary, config: ClassificationConfig, naming: NamingConfig) {
        self.library = library
        self.config = config
        self.naming = naming
    }

    /// The logic every archive starts with: the organising principles distilled from records-management practice.
    public func builtinLogic() throws -> String { try library.template(Self.principlesKey) }

    static let principlesKey = "organizing-principles"

    /// The archive's logic as the model reads it, with `{{placeholders}}` filled in.
    public func logicBlock(_ logic: LogicRecord?, folderLanguage: String) throws -> String {
        guard let logic, !logic.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "(none — organise the archive the way a careful archivist would)"
        }
        return try PromptLibrary.fill(logic.body, ["folder_language": folderLanguage], name: Self.logicName)
    }

    /// How the logic is named when a placeholder in it cannot be filled.
    static let logicName = "the archive's logic"

    public func classifySystem(folderLanguage: String, logic: LogicRecord?) throws -> String {
        try library.render("classify-system", [
            "logic": try logicBlock(logic, folderLanguage: folderLanguage),
            "field_rules": try library.render("field-rules", ["max_tags": String(config.maxTags)]),
            "file_name_rule": try fileNameRule(),
        ])
    }

    /// How a file is named, the same wherever the model names one; the logic can override it.
    func fileNameRule() throws -> String {
        try library.render("file-name-rule", ["max_name_chars": String(naming.maxChars)])
    }

    /// Naming a document that learned evidence has already placed: the logic and the naming rule, nothing else.
    public func nameSystem(folderLanguage: String, logic: LogicRecord?) throws -> String {
        try library.render("name-system", [
            "logic": try logicBlock(logic, folderLanguage: folderLanguage),
            "file_name_rule": try fileNameRule(),
        ])
    }

    public func nameUser(content: ExtractedContent, decision: FilingDecision, folder: TaxonomyFolder, taxonomy: TaxonomySnapshot,
                         correspondents: [CorrespondentMatch]) throws -> String {
        let recent = folder.recentTitles.prefix(config.promptExamplesPerFolder)
        let known = [("Correspondent", decision.correspondent), ("Document type", decision.documentType == .other ? nil : decision.documentType.rawValue),
                     ("Document date", decision.documentDate)]
            .compactMap { label, value in value.map { "\(label): \($0)" } }
        return try library.render("name-user", [
            "folder": "\(taxonomy.path(of: folder)) — \(folder.description)",
            "recent": recent.isEmpty ? "(none yet)" : recent.map { "- \($0)" }.joined(separator: "\n"),
            "known": known.isEmpty ? "(nothing beyond the document itself)" : known.joined(separator: "\n"),
            "document": documentBlock(content, correspondents: correspondents),
        ])
    }

    /// Deciding the path: only the document. Shown any folder, a model copies it whether it fits or not.
    public func classifyUser(content: ExtractedContent, correspondents: [CorrespondentMatch]) throws -> String {
        try library.render("document-user", ["document": documentBlock(content, correspondents: correspondents)])
    }

    /// Picking out a document's signals, which become its labels. The archive's logic plays no part: labels say what
    /// the document concerns, whatever folder it is filed in.
    public func labelsSystem(maxPerKind: Int) throws -> String {
        try library.render("labels-system", ["max_per_kind": String(maxPerKind)])
    }

    /// The document whose signals are picked out, as the model deciding its path sees it, less the senders the app
    /// recognised: those say who sent it, not what it concerns.
    public func labelsUser(content: ExtractedContent) throws -> String {
        try library.render("document-user", ["document": documentBlock(content, correspondents: [])])
    }

    /// Asking which of the folders beside a decided one, if any, it is.
    public func judgeSystem(folderLanguage: String, logic: LogicRecord?) throws -> String {
        try library.render("judge-system", ["logic": try logicBlock(logic, folderLanguage: folderLanguage)])
    }

    /// The document being filed, as the question of which folder it is at home in shows it.
    public static func judgedDocument(title: String, type: DocumentType, sender: String?) -> String {
        [("Title", Optional(title)), ("Type", type == .other ? nil : type.rawValue), ("From", sender)]
            .compactMap { label, value in value.map { "\(label): \($0)" } }.joined(separator: "\n")
    }

    /// The document, the decided folder and the folders it may be, numbered from 1 in the order given, each with what
    /// it holds.
    public func judgeUser(level: FolderLevel, candidates: [TaxonomyFolder], place: String, document: String) throws -> String {
        let options = candidates.enumerated().map { index, folder in
            let recent = folder.recentTitles.prefix(config.promptExamplesPerFolder)
            return "\(index + 1). \(folder.name) — \(folder.description)"
                + (recent.isEmpty ? "" : "\n   Holds, for example: " + recent.map { "\"\($0)\"" }.joined(separator: "; "))
        }
        return try library.render("judge-user", [
            "document": document,
            "place": place.isEmpty ? "(the top of the archive)" : place,
            "decided": "\(level.name) — \(level.description)",
            "existing": options.joined(separator: "\n"),
        ])
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
