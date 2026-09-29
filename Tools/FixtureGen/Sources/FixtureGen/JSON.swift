/// A JSON value with ordered object keys. `JSONEncoder` lays keys out in hash order, which Swift seeds per
/// process, so it cannot produce a reproducible or reviewable expected.json.
indirect enum JSON {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case integer(UInt64)
    case bool(Bool)
    case null

    /// Pretty-printed with two-space indentation; arrays of scalars stay on one line.
    func rendered(indent: Int = 0) -> String {
        let padding = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let lines = members.map { "\(inner)\(JSON.quoted($0.0)): \($0.1.rendered(indent: indent + 1))" }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(padding)}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            if items.allSatisfy(\.isScalar) {
                return "[" + items.map { $0.rendered() }.joined(separator: ", ") + "]"
            }
            return "[\n" + items.map { inner + $0.rendered(indent: indent + 1) }.joined(separator: ",\n") + "\n\(padding)]"
        case .string(let text):
            return JSON.quoted(text)
        case .integer(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private var isScalar: Bool {
        switch self {
        case .object, .array: false
        case .string, .integer, .bool, .null: true
        }
    }

    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

extension Optional {
    /// `.null` for nil, otherwise the wrapped value converted by `transform`.
    func json(_ transform: (Wrapped) -> JSON) -> JSON {
        map(transform) ?? .null
    }
}
