import Foundation

public enum JSONError: Error, LocalizedError, Equatable {
    /// A value of the named type could not be written as JSON, for the reason given.
    case notEncodable(String, String)

    public var errorDescription: String? {
        switch self {
        case let .notEncodable(type, why): "A \(type) could not be written as JSON: \(why)"
        }
    }
}

public enum JSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `value` as JSON. A value JSON cannot hold, such as a number that is not finite, throws `JSONError.notEncodable`,
    /// naming its type and why, never its contents: nothing is stored in its place, as "null" would read back as no value.
    public static func string(_ value: some Encodable, pretty: Bool = false) throws -> String {
        do {
            return String(decoding: try (pretty ? prettyEncoder : encoder).encode(value), as: UTF8.self)
        } catch {
            throw JSONError.notEncodable(String(describing: type(of: value)), String(describing: error))
        }
    }

    /// Decodes JSON the app stored itself; nil for none. Stored JSON that cannot be read is logged with its type and
    /// the field that failed, never its value, which may hold the document's text (AGENTS.md §4.1), and read as none.
    public static func decode<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let string else { return nil }
        do {
            return try decoder.decode(type, from: Data(string.utf8))
        } catch {
            Log.error(.db, "Stored JSON could not be read", ["type": String(describing: type), "field": field(of: error)])
            return nil
        }
    }

    /// Where decoding failed, as a dotted path of coding keys.
    static func field(of error: any Error) -> String {
        let path: [any CodingKey] = switch error as? DecodingError {
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context): context.codingPath
        case let .keyNotFound(key, context): context.codingPath + [key]
        case nil, .some: []
        }
        return path.isEmpty ? "(root)" : path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
}

public struct JSONEntry: Sendable, Codable, Hashable {
    public var key: String
    public var value: JSONValue
    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// Minimal dynamic JSON value, used for trace payloads, configuration merging and Ollama schemas.
/// `orderedObject` keeps key order, which matters for JSON-schema-constrained generation.
public enum JSONValue: Sendable, Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case orderedObject([JSONEntry])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        case let .orderedObject(entries):
            try c.encode(Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last }))
        }
    }

    public subscript(key: String) -> JSONValue? {
        switch self {
        case let .object(o): o[key]
        case let .orderedObject(entries): entries.last { $0.key == key }?.value
        default: nil
        }
    }

    /// Deterministic JSON text: ordered objects keep their order, plain objects are key-sorted.
    public func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(n):
            if n.isFinite, n == n.rounded(), abs(n) < 1e15 { out += String(Int64(n)) } else if n.isFinite { out += String(n) } else { out += "null" }
        case let .string(s): Self.writeString(s, into: &out)
        case let .array(a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case let .object(o):
            Self.writeObject(o.keys.sorted().map { JSONEntry($0, o[$0] ?? .null) }, into: &out)
        case let .orderedObject(entries):
            Self.writeObject(entries, into: &out)
        }
    }

    private static func writeObject(_ entries: [JSONEntry], into out: inout String) {
        out += "{"
        for (i, e) in entries.enumerated() {
            if i > 0 { out += "," }
            writeString(e.key, into: &out)
            out += ":"
            e.value.write(into: &out)
        }
        out += "}"
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
    public var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { a } else { nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}
