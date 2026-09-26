import ArrumatorCore
import Foundation

/// JSON schemas sent as Ollama `format`. Property order is deliberate: the model first states its evidence, then
/// describes the home the logic gives this document, as a path of folders from the top of the archive; the file name
/// comes after the folder so it can follow that folder's naming pattern. The app, not the model, maps the path onto
/// the folders that exist. Only string/number/object/array/enum types are used, which every grammar backend supports.
public enum ClassificationSchema {
    static let yes = "yes"
    static let no = "no"
    static let unsure = "unsure"

    static func string(_ enumValues: [String]? = nil) -> JSONValue {
        var e: [JSONEntry] = [JSONEntry("type", "string")]
        if let enumValues { e.append(JSONEntry("enum", .array(enumValues.map(JSONValue.string)))) }
        return .orderedObject(e)
    }

    static func stringArray(maxItems: Int) -> JSONValue {
        .orderedObject([JSONEntry("type", "array"), JSONEntry("items", string()), JSONEntry("maxItems", .number(Double(maxItems)))])
    }

    static func object(_ properties: [JSONEntry]) -> JSONValue {
        .orderedObject([
            JSONEntry("type", "object"),
            JSONEntry("properties", .orderedObject(properties)),
            JSONEntry("required", .array(properties.map { .string($0.key) })),
        ])
    }

    public static func classify(languages: [String], maxTags: Int, maxDepth: Int) -> JSONValue {
        object([
            JSONEntry("rationale", string()),
            JSONEntry("correspondent", string()),
            JSONEntry("subject", string()),
            JSONEntry("document_type", string(DocumentType.allCases.map(\.rawValue))),
            JSONEntry("document_date", string()),
            JSONEntry("period_year", string()),
            JSONEntry("language", string(languages + ["other"])),
            JSONEntry("title", string()),
            JSONEntry("tags", stringArray(maxItems: maxTags)),
            JSONEntry("ideal_path", .orderedObject([
                JSONEntry("type", "array"),
                JSONEntry("items", object([JSONEntry("name", string()), JSONEntry("description", string())])),
                JSONEntry("minItems", .number(1)),
                JSONEntry("maxItems", .number(Double(maxDepth))),
            ])),
            JSONEntry("ideal_year_folder", string([no, yes])),
            JSONEntry("file_name", string()),
            JSONEntry("confidence", .orderedObject([JSONEntry("type", "number")])),
        ])
    }

    /// Whether a decided folder is one that exists: "yes", "no" or "unsure".
    public static func sameFolder() -> JSONValue {
        object([JSONEntry("same", string([yes, no, unsure]))])
    }

    public static func folderDescription(maxExamples: Int) -> JSONValue {
        object([JSONEntry("description", string()), JSONEntry("examples", stringArray(maxItems: maxExamples))])
    }

    /// Only a file name, for a document learned evidence has already placed.
    public static func fileName() -> JSONValue {
        object([JSONEntry("file_name", string())])
    }
}

/// The model's answer when it only names a document.
struct FileNameAnswer: Decodable {
    var fileName: String

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
    }
}

/// Raw model answer, keys as in the schema.
public struct ModelDecisionAnswer: Sendable, Codable, Hashable {
    public var rationale: String
    public var correspondent: String
    /// Whom the document is about or addressed to, as it names them; "" when it does not say.
    public var subject: String
    public var documentType: String
    public var documentDate: String
    public var periodYear: String
    public var language: String
    public var title: String
    public var tags: [String]
    public var idealPath: [ModelFolderLevel]
    public var idealYearFolder: String
    public var fileName: String
    public var confidence: Double

    enum CodingKeys: String, CodingKey {
        case rationale, correspondent, subject
        case documentType = "document_type"
        case documentDate = "document_date"
        case periodYear = "period_year"
        case language, title, tags
        case idealPath = "ideal_path"
        case idealYearFolder = "ideal_year_folder"
        case fileName = "file_name"
        case confidence
    }
}

/// One folder of the path the model decides by the logic. What it stands for is not the model's to say: the app
/// works it out from what the document is identified as (`FilingClassifier.marked`).
public struct ModelFolderLevel: Sendable, Codable, Hashable {
    public var name: String
    public var description: String
}

/// The model's answer to whether a decided folder is one that exists.
public struct SameFolderAnswer: Sendable, Codable, Hashable {
    public var same: String

    /// true, false, or nil when the model could not tell.
    public var verdict: Bool? {
        switch same {
        case ClassificationSchema.yes: true
        case ClassificationSchema.no: false
        default: nil
        }
    }
}

public struct FolderDescriptionAnswer: Sendable, Codable, Hashable {
    public var description: String
    public var examples: [String]
}

/// A validated model decision with normalised values and notes on what was corrected.
public struct ValidatedDecision: Sendable, Codable, Hashable {
    public var raw: ModelDecisionAnswer
    /// The home the logic gives this document, from the top of the archive down, as the model described it.
    public var ideal: [FolderLevel]
    /// This document goes in a year folder inside that home.
    public var yearFolder: Bool
    public var documentType: DocumentType
    public var documentDate: String?
    public var periodYear: Int?
    public var tags: [String]
    public var language: String
    public var confidence: Double
    public var notes: [String]
}

public enum AnswerValidationError: Error, LocalizedError, Hashable {
    case notJSON(String)
    case invalid([String])

    public var errorDescription: String? {
        switch self {
        case let .notJSON(why): "The answer is not valid JSON: \(why)"
        case let .invalid(problems): problems.joined(separator: "; ")
        }
    }
}

/// Parses and checks model output. Recoverable issues are normalised; violations go back to the model for repair.
public struct AnswerValidator: Sendable {
    public let titleMaxChars: Int
    public let maxTags: Int
    public let languages: [String]
    public let plausibleYears: ClosedRange<Int>
    public let maxDepth: Int
    /// Cleans folder names as file names are cleaned: no path separators or control characters reach a directory.
    public let names: FilenameBuilder
    /// The archive's logic, folded for comparison: a path that repeats its own names for its levels is no answer.
    public let logic: String?
    /// The logic's names for its levels, where it lays them out as a sequence ("Jurisdiction / Subject / …"), folded.
    public let levelNames: [String]

    public init(config: ClassificationConfig, entities: EntityConfig, naming: NamingConfig, languages: [String], maxDepth: Int,
                logic: String?, now: Date = Date()) {
        self.maxDepth = maxDepth
        self.logic = logic.map(Self.folded)
        levelNames = logic.map(Self.levelNames(in:)) ?? []
        names = FilenameBuilder(config: naming)
        titleMaxChars = config.titleMaxChars
        maxTags = config.maxTags
        self.languages = languages
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        plausibleYears = (year - entities.yearsBack)...(year + entities.yearsForward)
    }

    static func stripThinking(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}") { t = String(t[start...end]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func validate(_ text: String) throws -> ValidatedDecision {
        let raw: ModelDecisionAnswer
        do { raw = try JSONDecoder().decode(ModelDecisionAnswer.self, from: Data(Self.stripThinking(text).utf8)) } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
        var problems: [String] = []
        var notes: [String] = []
        let (ideal, trailingYear) = idealPath(raw.idealPath, problems: &problems, notes: &notes)
        guard problems.isEmpty else { throw AnswerValidationError.invalid(problems) }
        let type = DocumentType(lenient: raw.documentType)
        if type.rawValue != raw.documentType { notes.append("document_type \(raw.documentType) → \(type.rawValue)") }
        let date = Self.normalizeDate(raw.documentDate)
        if !raw.documentDate.isEmpty && date == nil { notes.append("unparseable date \(raw.documentDate)") }
        let period = Int(raw.periodYear.prefix(4)).flatMap { plausibleYears.contains($0) ? $0 : nil }
        var r = raw
        r.title = String(raw.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(titleMaxChars))
        var seen = Set<String>()
        let tags = Array(raw.tags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(maxTags))
        return ValidatedDecision(raw: r, ideal: ideal, yearFolder: trailingYear || raw.idealYearFolder == ClassificationSchema.yes,
                                 documentType: type,
                                 documentDate: date,
                                 periodYear: period, tags: tags, language: languages.contains(raw.language) ? raw.language : "other",
                                 confidence: min(1, max(0, raw.confidence)), notes: notes)
    }

    /// The folders of the ideal path, normalised; what cannot be a folder's name goes back to the model for repair.
    /// A logic may spell out the year as the last level ("… / Institution / [YYYY Year]"): a trailing year is the year
    /// folder, not a folder, so it is taken off the path and asks for one. A name is cleaned the way file names are,
    /// so "Global / Cross-Border" becomes "Global - Cross-Border", and a level that repeats the one above is dropped.
    private func idealPath(_ path: [ModelFolderLevel], problems: inout [String], notes: inout [String]) -> (levels: [FolderLevel], yearFolder: Bool) {
        var path = path
        var trailingYear = false
        while let last = path.last, path.count > 1, YearFolder.matches(last.name.trimmingCharacters(in: .whitespacesAndNewlines)) {
            path.removeLast()
            trailingYear = true
        }
        if trailingYear { notes.append("the year at the end of ideal_path is its year folder") }
        if path.isEmpty { problems.append("ideal_path must name at least one folder") }
        var levels: [FolderLevel] = []
        for (index, level) in path.enumerated() {
            let name = names.sanitize(level.name)
            let at = "ideal_path[\(index)]"
            if name != level.name.trimmingCharacters(in: .whitespacesAndNewlines) { notes.append("\(at).name “\(level.name)” → “\(name)”") }
            if name.isEmpty { problems.append("\(at).name must not be empty") }
            if DocumentType(rawValue: name.lowercased().replacingOccurrences(of: " ", with: "-")) != nil {
                problems.append("\(at).name must be a subject such as \"Identity Documents\" or \"Banking\", not a document_type value")
            }
            if YearFolder.matches(name) { problems.append("\(at).name must not be a year; ideal_year_folder asks for the year folder") }
            if names(levelNames, include: name) {
                problems.append("\(at).name \"\(name)\" is the LOGIC's own name for a level; name the folder with what that level is for this document")
            }
            if let above = levels.last, TaxonomyStore.sameName(above.name, name) {
                notes.append("\(at).name repeats the folder above it and is dropped")
                continue
            }
            levels.append(FolderLevel(name: name, description: level.description.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if levels.count > maxDepth { problems.append("ideal_path has \(levels.count) folders; the archive allows at most \(maxDepth)") }
        if levels.count > 1, let logic, logic.contains(Self.folded(levels.map(\.name).joined(separator: " / "))) {
            problems.append("ideal_path repeats the LOGIC's own names for its levels; name each folder with what that level is for this document")
        }
        return (levels, trailingYear)
    }

    /// Where the logic lays its levels out as a sequence of three or more names separated by " / ", those names;
    /// brackets are dropped. The first may end a sentence ("Build paths as Jurisdiction"), so its last word counts too.
    static func levelNames(in logic: String) -> [String] {
        let trimmed = CharacterSet(charactersIn: "[](){}.,;:*- ").union(.whitespaces)
        return logic.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let parts = line.components(separatedBy: " / ").map { folded($0.trimmingCharacters(in: trimmed)) }
            guard parts.count >= 3, let first = parts.first else { return [] }
            return parts + (first.split(separator: " ").last.map { [String($0)] } ?? [])
        }
    }

    private func names(_ labels: [String], include name: String) -> Bool { labels.contains(Self.folded(name)) }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The verdict in an answer to whether two folders are the same.
    public static func sameFolder(_ text: String) throws -> Bool? {
        do { return try JSONDecoder().decode(SameFolderAnswer.self, from: Data(stripThinking(text).utf8)).verdict } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
    }

    /// The file name in an answer that only names a document.
    public static func fileName(_ text: String) throws -> String {
        let answer: FileNameAnswer
        do { answer = try JSONDecoder().decode(FileNameAnswer.self, from: Data(stripThinking(text).utf8)) } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
        let name = answer.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AnswerValidationError.invalid(["file_name must not be empty"]) }
        return name
    }

    /// Accepts ISO dates and day-first `dd.mm.yyyy` / `dd/mm/yyyy`; returns ISO `YYYY-MM-DD` or nil.
    static func normalizeDate(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let m = t.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/) { return valid(Int(m.1), Int(m.2), Int(m.3)) }
        if let m = t.wholeMatch(of: /(\d{1,2})[.\/-](\d{1,2})[.\/-](\d{4})/) { return valid(Int(m.3), Int(m.2), Int(m.1)) }
        return nil
    }

    private static func valid(_ y: Int?, _ m: Int?, _ d: Int?) -> String? {
        guard let y, let m, let d else { return nil }
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        guard c.isValidDate(in: Calendar(identifier: .gregorian)) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
