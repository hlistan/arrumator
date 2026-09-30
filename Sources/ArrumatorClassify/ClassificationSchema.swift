import ArrumatorCore
import Foundation

/// The JSON schema sent as Ollama `format`: one list of signals per `LabelKind`, then the file name. Under
/// constrained decoding the model writes the properties in this order, so what a file name is made of (the sender,
/// the type, the date) comes first, and the name last, from what it has found. Only string, array and object types are
/// used, which every grammar backend supports.
public enum ClassificationSchema {
    static func string(_ enumValues: [String]? = nil) -> JSONValue {
        var e: [JSONEntry] = [JSONEntry("type", "string")]
        if let enumValues { e.append(JSONEntry("enum", .array(enumValues.map(JSONValue.string)))) }
        return .orderedObject(e)
    }

    static func stringArray(maxItems: Int, enumValues: [String]? = nil) -> JSONValue {
        .orderedObject([JSONEntry("type", "array"), JSONEntry("items", string(enumValues)), JSONEntry("maxItems", .number(Double(maxItems)))])
    }

    static func object(_ properties: [JSONEntry]) -> JSONValue {
        .orderedObject([
            JSONEntry("type", "object"),
            JSONEntry("properties", .orderedObject(properties)),
            JSONEntry("required", .array(properties.map { .string($0.key) })),
        ])
    }

    /// The kinds in the order the model writes them.
    static let answerOrder: [LabelKind] = [.sender, .type, .date, .party, .topic, .object, .reference, .period, .deadline, .amount,
                                           .jurisdiction, .language]

    /// The document's signals, the most significant first, and its file name. A type is one of `DocumentType` other
    /// than `other`: a document no type fits has none.
    public static func analysis(maxPerKind: Int) -> JSONValue {
        let types = DocumentType.allCases.filter { $0 != .other }.map(\.rawValue)
        return object(answerOrder.map { kind in
            JSONEntry(labelsKey(kind), stringArray(maxItems: kind.isSingle ? 1 : maxPerKind, enumValues: kind == .type ? types : nil))
        } + [JSONEntry(fileNameKey, string())])
    }

    /// The answer's key for the labels of `kind`: "senders", "parties", "types", …
    static func labelsKey(_ kind: LabelKind) -> String { kind == .party ? "parties" : kind.rawValue + "s" }

    static let fileNameKey = "file_name"
}

/// Raw model answer: a list per kind, and the file name.
struct AnalysisAnswer: Decodable {
    var signals: [LabelKind: [String]]
    var fileName: String

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var signals: [LabelKind: [String]] = [:]
        for kind in LabelKind.allCases {
            signals[kind] = try container.decode([String].self, forKey: Key(stringValue: ClassificationSchema.labelsKey(kind)))
        }
        self.signals = signals
        fileName = try container.decode(String.self, forKey: Key(stringValue: ClassificationSchema.fileNameKey))
    }
}

/// A validated answer: the labels, cleaned, the file name, and notes on what was changed or dropped.
public struct ValidatedAnalysis: Sendable, Codable, Hashable {
    public var labels: [DocumentLabel]
    public var fileName: String?
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

/// Parses and checks the model's answer. Each signal is kept as `DocumentLabel.normalized` keeps it, cut to
/// `maxValueChars`, once however it is written; each kind keeps its most significant first, at most `maxPerKind` of it
/// (one of a single-valued kind). What is no label of its kind is dropped rather than repaired, and noted; a list
/// missing from the answer goes back to the model.
public struct AnswerValidator: Sendable {
    public let labels: LabelsConfig

    public init(labels: LabelsConfig) {
        self.labels = labels
    }

    public func validate(_ text: String) throws -> ValidatedAnalysis {
        let raw: AnalysisAnswer
        do {
            raw = try JSONDecoder().decode(AnalysisAnswer.self, from: Data(ModelOutput.jsonObject(text).utf8))
        } catch let DecodingError.keyNotFound(key, _) {
            throw AnswerValidationError.invalid(["\(key.stringValue) is missing; give [] when the document shows none"])
        } catch {
            throw AnswerValidationError.notJSON(String(describing: error))
        }
        var notes: [String] = []
        let kept = ClassificationSchema.answerOrder.flatMap { labels(of: $0, in: raw, notes: &notes) }
        // Kinds in their own order, as the rest of the app lists them.
        let ordered = LabelKind.allCases.flatMap { kind in kept.filter { $0.kind == kind } }
        let name = DocumentLabel.oneLine(raw.fileName)
        return ValidatedAnalysis(labels: ordered, fileName: name.isEmpty ? nil : name, notes: notes)
    }

    private func labels(of kind: LabelKind, in raw: AnalysisAnswer, notes: inout [String]) -> [DocumentLabel] {
        let key = ClassificationSchema.labelsKey(kind)
        let limit = kind.isSingle ? 1 : labels.maxPerKind
        var seen = Set<String>()
        var kept: [DocumentLabel] = []
        for written in raw.signals[kind] ?? [] where !DocumentLabel.oneLine(written).isEmpty {
            guard var label = DocumentLabel.normalized(written, kind: kind) else {
                notes.append("\(key): “\(DocumentLabel.oneLine(written))” is no \(kind.rawValue), dropped")
                continue
            }
            label.value = shortened(label.value)
            guard seen.insert(Self.folded(label.value)).inserted else { continue }
            guard seen.count <= limit else {
                notes.append("\(key): more than \(limit), the rest dropped")
                break
            }
            kept.append(label)
        }
        return kept
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
}
