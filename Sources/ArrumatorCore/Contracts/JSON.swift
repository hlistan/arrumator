import Foundation

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

    public static func string(_ value: some Encodable, pretty: Bool = false) -> String {
        guard let data = try? (pretty ? prettyEncoder : encoder).encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
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
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
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
    public var doubleValue: Double? {
        switch self {
        case let .number(n): n
        case let .string(s): Double(s)
        default: nil
        }
    }
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
