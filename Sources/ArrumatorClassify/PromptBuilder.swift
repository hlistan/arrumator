import ArrumatorCore
import Foundation

/// Renders the placement prompt from templates plus the current folder tree, learned hints, similar past filings
/// and the document itself.
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
        let area = folder.parentCode.flatMap { taxonomy.folder(code: $0) }.map { " (in \($0.code) \($0.name))" } ?? ""
        let recent = folder.recentTitles.prefix(config.promptExamplesPerFolder)
        let known = [("Correspondent", decision.correspondent), ("Document type", decision.documentType == .other ? nil : decision.documentType.rawValue),
                     ("Document date", decision.documentDate)]
            .compactMap { label, value in value.map { "\(label): \($0)" } }
        return try library.render("name-user", [
            "folder": "\(folder.code) \(folder.name)\(area) — \(folder.description)",
            "recent": recent.isEmpty ? "(none yet)" : recent.map { "- \($0)" }.joined(separator: "\n"),
            "known": known.isEmpty ? "(nothing beyond the document itself)" : known.joined(separator: "\n"),
            "document": documentBlock(content, correspondents: correspondents),
        ])
    }

    public func classifyUser(content: ExtractedContent, candidates: CandidateSet, taxonomy: TaxonomySnapshot,
                             hints: [String], correspondents: [CorrespondentMatch]) throws -> String {
        try library.render("classify-user", [
            "folders": folderBlock(candidates, taxonomy: taxonomy),
            "areas": areaBlock(taxonomy),
            "hints": hints.isEmpty ? "(none)" : hints.map { "- \($0)" }.joined(separator: "\n"),
            "memories": memoryBlock(candidates.memories, taxonomy: taxonomy),
            "document": documentBlock(content, correspondents: correspondents),
        ])
    }

    public func repair(errors: String) throws -> String {
        try library.render("repair-user", ["errors": errors])
    }

    func folderBlock(_ set: CandidateSet, taxonomy: TaxonomySnapshot) -> String {
        guard !set.ranked.isEmpty else { return "(none yet — the archive is empty, so propose the first folder)" }
        var lines: [String] = []
        for (rank, candidate) in set.ranked.enumerated() {
            guard let f = taxonomy.folder(code: candidate.code) else { continue }
            let area = f.parentCode.flatMap { taxonomy.folder(code: $0) }.map { " (in \($0.code) \($0.name))" } ?? ""
            lines.append("- \(f.code) \(f.name)\(area) — \(f.description)")
            if rank < config.promptDetailedFolders, !f.body.isEmpty {
                let body = f.body.replacingOccurrences(of: "\n", with: " ").prefix(config.promptFolderBodyChars)
                lines.append("  Details: \(body)")
            }
            let recent = f.recentTitles.prefix(config.promptExamplesPerFolder)
            if !recent.isEmpty { lines.append("  Recent files: " + recent.map { "\"\($0)\"" }.joined(separator: "; ")) }
            if !f.learnedCorrespondents.isEmpty { lines.append("  Usual correspondents: " + f.learnedCorrespondents.joined(separator: ", ")) }
            if f.yearSubfolders { lines.append("  Split by year") }
        }
        return lines.joined(separator: "\n")
    }

    func areaBlock(_ taxonomy: TaxonomySnapshot) -> String {
        let areas = taxonomy.areas.filter { area in taxonomy.children(of: area.code).allSatisfy { $0.role == nil } && area.origin != .system }
        guard !areas.isEmpty else { return "(none yet)" }
        return areas.map { "- \($0.code) \($0.name) — \($0.description)" }.joined(separator: "\n")
    }

    func memoryBlock(_ memories: [ScoredMemory], taxonomy: TaxonomySnapshot) -> String {
        guard !memories.isEmpty else { return "(none yet)" }
        return memories.enumerated().map { i, m in
            let folder = taxonomy.folder(id: m.memory.folderID).map { "\($0.code) \($0.name)" } ?? m.memory.folderCode
            return "\(i + 1). → \(folder) | \(m.memory.summaryLine) | similarity \(String(format: "%.2f", m.similarity))"
        }.joined(separator: "\n")
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
