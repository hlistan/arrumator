import ArrumatorCore
import Foundation

/// JSON schemas sent as Ollama `format`. Property order is deliberate: the model first states its evidence, then
/// describes the ideal home a well-organised archive would give this document, and only then maps that ideal onto
/// the existing folders (or creates it); the file name comes after the folder so it can follow that folder's naming
/// pattern. Only string/number/array/enum types are used, which every grammar backend supports.
public enum ClassificationSchema {
    public static let newCode = "NEW"
    static let yes = "yes"
    static let no = "no"

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

    public static func classify(folders: [String], areas: [String], languages: [String], maxTags: Int) -> JSONValue {
        object([
            JSONEntry("rationale", string()),
            JSONEntry("correspondent", string()),
            JSONEntry("document_type", string(DocumentType.allCases.map(\.rawValue))),
            JSONEntry("document_date", string()),
            JSONEntry("period_year", string()),
            JSONEntry("language", string(languages + ["other"])),
            JSONEntry("title", string()),
            JSONEntry("tags", stringArray(maxItems: maxTags)),
            JSONEntry("ideal_area", string()),
            JSONEntry("ideal_area_description", string()),
            JSONEntry("ideal_category", string()),
            JSONEntry("ideal_category_description", string()),
            JSONEntry("ideal_year_folders", string([no, yes])),
            JSONEntry("folder_code", string(folders + [newCode])),
            JSONEntry("new_folder_area_code", string([""] + areas + [newCode])),
            JSONEntry("file_name", string()),
            JSONEntry("confidence", .orderedObject([JSONEntry("type", "number")])),
        ])
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
    public var documentType: String
    public var documentDate: String
    public var periodYear: String
    public var language: String
    public var title: String
    public var tags: [String]
    public var idealArea: String
    public var idealAreaDescription: String
    public var idealCategory: String
    public var idealCategoryDescription: String
    public var idealYearFolders: String
    public var folderCode: String
    public var newFolderAreaCode: String
    public var fileName: String
    public var confidence: Double

    enum CodingKeys: String, CodingKey {
        case rationale, correspondent
        case documentType = "document_type"
        case documentDate = "document_date"
        case periodYear = "period_year"
        case language, title, tags
        case idealArea = "ideal_area"
        case idealAreaDescription = "ideal_area_description"
        case idealCategory = "ideal_category"
        case idealCategoryDescription = "ideal_category_description"
        case idealYearFolders = "ideal_year_folders"
        case folderCode = "folder_code"
        case newFolderAreaCode = "new_folder_area_code"
        case fileName = "file_name"
        case confidence
    }
}

public struct FolderDescriptionAnswer: Sendable, Codable, Hashable {
    public var description: String
    public var examples: [String]
}

/// A validated model decision with normalised values and notes on what was corrected.
public struct ValidatedDecision: Sendable, Codable, Hashable {
    public var raw: ModelDecisionAnswer
    /// Existing folder, or nil when `newFolder` is set.
    public var folderCode: String?
    public var newFolder: FolderSpec?
    /// The home a well-organised archive would give this document, as the model described it.
    public var ideal: FolderSpec
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
    public let taxonomy: TaxonomySnapshot
    public let titleMaxChars: Int
    public let maxTags: Int
    public let languages: [String]
    public let plausibleYears: ClosedRange<Int>

    public init(taxonomy: TaxonomySnapshot, config: ClassificationConfig, entities: EntityConfig, languages: [String],
                now: Date = Date()) {
        self.taxonomy = taxonomy
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
        var category = raw.idealCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        var areaName = raw.idealArea.trimmingCharacters(in: .whitespacesAndNewlines)
        // The tree is shown as "10-19 Insurance & Legal", and models echo it so. An echoed area code that exists is
        // that area, whatever the name; any other code is dropped, never made part of a new folder's name.
        var idealAreaCode: String?
        if let echo = JDCode.echoedCode(in: areaName), JDCode.isArea(echo.code) {
            areaName = echo.name
            if taxonomy.folder(code: echo.code)?.kind == .area { idealAreaCode = echo.code }
            notes.append("ideal_area \(raw.idealArea) → \(idealAreaCode.map { "area \($0)" } ?? echo.name)")
        }
        if let echo = JDCode.echoedCode(in: category), JDCode.isCategory(echo.code),
           taxonomy.folder(code: echo.code) != nil || (idealAreaCode != nil && JDCode.area(of: echo.code) == idealAreaCode) {
            category = echo.name
            notes.append("ideal_category \(raw.idealCategory) → \(echo.name)")
        }
        if category.isEmpty { problems.append("ideal_category must name the category this document belongs to") }
        let normalizedCategory = category.lowercased().replacingOccurrences(of: " ", with: "-")
        if DocumentType(rawValue: normalizedCategory) != nil {
            problems.append("ideal_category must be a life topic such as \"Identity Documents\" or \"Medical Records\", not a document_type value")
        }
        if !category.isEmpty, category.caseInsensitiveCompare(areaName) == .orderedSame {
            problems.append("ideal_category must be a specific topic inside ideal_area, not the area itself")
        }
        if areaName.isEmpty { problems.append("ideal_area must name the area this document belongs to") }
        if (category + areaName).contains("/") || (category + areaName).contains(":") {
            problems.append("ideal_area and ideal_category must not contain / or :")
        }
        let yearly = raw.idealYearFolders == ClassificationSchema.yes
        var ideal = FolderSpec(areaCode: idealAreaCode, newAreaName: idealAreaCode == nil ? areaName : nil,
                               newAreaDescription: idealAreaCode == nil ? raw.idealAreaDescription : nil, name: category,
                               description: raw.idealCategoryDescription, yearSubfolders: yearly, yearRule: yearly ? .documentDate : nil)
        var folderCode: String?
        var newFolder: FolderSpec?
        if raw.folderCode == ClassificationSchema.newCode {
            if raw.newFolderAreaCode == ClassificationSchema.newCode || raw.newFolderAreaCode.isEmpty {
                newFolder = ideal
            } else if taxonomy.folder(code: raw.newFolderAreaCode)?.kind == .area {
                ideal.areaCode = raw.newFolderAreaCode
                ideal.newAreaName = nil
                ideal.newAreaDescription = nil
                newFolder = ideal
            } else {
                problems.append("new_folder_area_code must be one of the AREAS codes or NEW")
            }
        } else if taxonomy.folder(code: raw.folderCode)?.acceptsFiles == true {
            folderCode = raw.folderCode
        } else {
            problems.append("folder_code \(raw.folderCode) is not an existing folder code or NEW")
        }
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
        return ValidatedDecision(raw: r, folderCode: folderCode, newFolder: newFolder, ideal: ideal, documentType: type, documentDate: date,
                                 periodYear: period, tags: tags, language: languages.contains(raw.language) ? raw.language : "other",
                                 confidence: min(1, max(0, raw.confidence)), notes: notes)
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
