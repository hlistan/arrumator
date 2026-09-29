import ArrumatorCore
import Foundation

/// The JSON schema sent as Ollama `format`. Property order is deliberate: the model first says what the document is,
/// then picks out its signals, and names the file last, from what it has found. Only string, array and object types
/// are used, which every grammar backend supports.
public enum ClassificationSchema {
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

    /// What the document is, its signals (one list per `LabelKind`, the most significant first), and its file name.
    public static func analysis(maxPerKind: Int) -> JSONValue {
        object([
            JSONEntry("correspondent", string()),
            JSONEntry("document_type", string(DocumentType.allCases.map(\.rawValue))),
            JSONEntry("document_date", string()),
            JSONEntry("period_year", string()),
            JSONEntry("title", string()),
        ] + LabelKind.allCases.map { JSONEntry(labelsKey($0), stringArray(maxItems: maxPerKind)) } + [
            JSONEntry("file_name", string()),
        ])
    }

    /// The answer's key for the labels of `kind`: "subjects", "objects", "jurisdictions", "languages".
    static func labelsKey(_ kind: LabelKind) -> String { kind.rawValue + "s" }
}

/// Raw model answer, keys as in the schema.
struct AnalysisAnswer: Decodable {
    var correspondent: String
    var documentType: String
    var documentDate: String
    var periodYear: String
    var title: String
    var subjects: [String]
    var objects: [String]
    var jurisdictions: [String]
    var languages: [String]
    var fileName: String

    enum CodingKeys: String, CodingKey {
        case correspondent
        case documentType = "document_type"
        case documentDate = "document_date"
        case periodYear = "period_year"
        case title, subjects, objects, jurisdictions, languages
        case fileName = "file_name"
    }

    func signals(_ kind: LabelKind) -> [String] {
        switch kind {
        case .subject: subjects
        case .object: objects
        case .jurisdiction: jurisdictions
        case .language: languages
        }
    }
}

/// A validated answer: its values normalised, its labels cleaned, and notes on what was changed or dropped.
public struct ValidatedAnalysis: Sendable, Codable, Hashable {
    public var correspondent: String?
    public var documentType: DocumentType
    public var documentDate: String?
    public var periodYear: Int?
    public var title: String?
    public var fileName: String?
    public var labels: [DocumentLabel]
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

/// Parses and checks the model's answer. Recoverable issues are normalised; a list missing from it goes back to the
/// model for repair. Each signal is tidied to one line and cut to length, repeats are dropped, each kind keeps its
/// most significant first, and a language becomes its ISO 639-1 code; a language that is none is dropped, as is
/// anything past `maxPerKind`.
public struct AnswerValidator: Sendable {
    public let titleMaxChars: Int
    public let labels: LabelsConfig
    public let plausibleYears: ClosedRange<Int>

    public init(config: AnalysisConfig, labels: LabelsConfig, entities: EntityConfig, now: Date = Date()) {
        titleMaxChars = config.titleMaxChars
        self.labels = labels
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        plausibleYears = (year - entities.yearsBack)...(year + entities.yearsForward)
    }

    static func stripThinking(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}") { t = String(t[start...end]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func validate(_ text: String) throws -> ValidatedAnalysis {
        let raw: AnalysisAnswer
        do {
            raw = try JSONDecoder().decode(AnalysisAnswer.self, from: Data(Self.stripThinking(text).utf8))
        } catch let DecodingError.keyNotFound(key, _) {
            throw AnswerValidationError.invalid(["\(key.stringValue) is missing; give \"\" or [] when the document shows none"])
        } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
        var notes: [String] = []
        let type = DocumentType(lenient: raw.documentType)
        if type.rawValue != raw.documentType { notes.append("document_type \(raw.documentType) → \(type.rawValue)") }
        let date = Self.normalizeDate(raw.documentDate)
        if !raw.documentDate.isEmpty && date == nil { notes.append("unparseable date \(raw.documentDate)") }
        let period = Int(raw.periodYear.prefix(4)).flatMap { plausibleYears.contains($0) ? $0 : nil }
        let title = Self.nonEmpty(String(Self.oneLine(raw.title).prefix(titleMaxChars)))
        return ValidatedAnalysis(correspondent: Self.nonEmpty(Self.oneLine(raw.correspondent)), documentType: type, documentDate: date,
                                 periodYear: period, title: title, fileName: Self.nonEmpty(Self.oneLine(raw.fileName)),
                                 labels: LabelKind.allCases.flatMap { labels(of: $0, in: raw, notes: &notes) }, notes: notes)
    }

    private func labels(of kind: LabelKind, in raw: AnalysisAnswer, notes: inout [String]) -> [DocumentLabel] {
        let key = ClassificationSchema.labelsKey(kind)
        var seen = Set<String>()
        var kept: [DocumentLabel] = []
        for written in raw.signals(kind) {
            var value = Self.oneLine(written)
            guard !value.isEmpty else { continue }
            if kind == .language {
                guard let code = DocumentLabel.languageCode(value) else {
                    notes.append("\(key): “\(value)” is not an ISO 639 language, dropped")
                    continue
                }
                value = code
            }
            value = shortened(value)
            guard seen.insert(Self.folded(value)).inserted else { continue }
            guard seen.count <= labels.maxPerKind else {
                notes.append("\(key): more than \(labels.maxPerKind), the rest dropped")
                break
            }
            kept.append(DocumentLabel(kind: kind, value: value))
        }
        return kept
    }

    /// Runs of white space, line breaks and control characters become one space.
    static func oneLine(_ text: String) -> String {
        text.unicodeScalars.split { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
    }

    /// At most `maxValueChars` characters, cut after the last whole word that fits when there is one.
    func shortened(_ value: String) -> String {
        guard value.count > labels.maxValueChars else { return value }
        // One character more, so a word ending exactly at the limit is seen to be whole.
        let cut = value.prefix(labels.maxValueChars + 1)
        guard let space = cut.lastIndex(of: " ") else { return String(value.prefix(labels.maxValueChars)) }
        return String(cut[..<space])
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

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
