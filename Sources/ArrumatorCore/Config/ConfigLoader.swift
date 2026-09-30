import Foundation

public enum ConfigError: Error, LocalizedError {
    case missingResource(String)
    case invalid(name: String, underlying: String)
    case archiveFolderMissing(String)

    public var errorDescription: String? {
        switch self {
        case let .missingResource(name): "Bundled configuration \(name) is missing"
        case let .invalid(name, underlying): "Configuration \(name) is invalid: \(underlying)"
        case let .archiveFolderMissing(path): "The archive folder \(path) does not exist, so it has no index yet"
        }
    }
}

/// Loads strongly typed configuration from bundled JSON defaults, deep-merged with an optional user override file.
/// The bundled file is the single source of every default; Swift types declare no default values.
public enum ConfigLoader {
    public static func bundledValue(_ name: String) throws -> JSONValue {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Defaults") else {
            throw ConfigError.missingResource("\(name).json")
        }
        return try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: url))
    }

    public static func load<T: Decodable>(_ type: T.Type, defaults name: String, overrides: [JSONValue] = []) throws -> T {
        var merged = try bundledValue(name)
        for o in overrides { merged = deepMerge(merged, o) }
        let value: T
        do {
            let data = try JSON.encoder.encode(merged)
            value = try JSON.decoder.decode(T.self, from: data)
        } catch {
            throw ConfigError.invalid(name: name, underlying: String(describing: error))
        }
        if let validated = value as? any ValidatedConfiguration, !validated.problems.isEmpty {
            throw ConfigError.invalid(name: name, underlying: validated.problems.joined(separator: "; "))
        }
        return value
    }

    public static func overrideValue(at url: URL) throws -> JSONValue? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: url))
    }

    /// Objects merge key by key; any other value in `override` replaces the base value.
    public static func deepMerge(_ base: JSONValue, _ override: JSONValue) -> JSONValue {
        guard case var .object(b) = base, case let .object(o) = override else { return override }
        for (key, value) in o {
            if case .null = value { continue }
            b[key] = b[key].map { deepMerge($0, value) } ?? value
        }
        return .object(b)
    }

    /// Minimal diff of `value` against `base`, so only user-changed keys are persisted.
    public static func diff(_ value: JSONValue, from base: JSONValue) -> JSONValue? {
        if value == base { return nil }
        guard case let .object(v) = value, case let .object(b) = base else { return value }
        var out: [String: JSONValue] = [:]
        for (key, sub) in v {
            if let baseSub = b[key] {
                if let d = diff(sub, from: baseSub) { out[key] = d }
            } else {
                out[key] = sub
            }
        }
        return out.isEmpty ? nil : .object(out)
    }
}

extension String {
    /// Expands a leading `~` to the user's home directory.
    public var expandingTilde: String { (self as NSString).expandingTildeInPath }
}

/// A list configuration may not leave empty, such as retry delays the pipeline picks from: an empty one is refused
/// when the configuration loads, with the key named, rather than found empty when the pipeline needs it.
public struct NonEmpty<Element: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public let first: Element
    public let rest: [Element]

    public init(_ first: Element, _ rest: [Element]) {
        self.first = first
        self.rest = rest
    }

    public var all: [Element] { [first] + rest }
    public var last: Element { rest.last ?? first }
    public var count: Int { rest.count + 1 }

    /// The element at `index`, or the last one past the end: the n-th retry waits the n-th delay, and every retry after
    /// the list the last one.
    public func clamped(_ index: Int) -> Element {
        let position = min(max(index, 0), rest.count)
        return position == 0 ? first : rest[position - 1]
    }

    public init(from decoder: any Decoder) throws {
        let values = try [Element](from: decoder)
        guard let first = values.first else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                    debugDescription: "must list at least one value"))
        }
        self.init(first, Array(values.dropFirst()))
    }

    public func encode(to encoder: any Encoder) throws { try all.encode(to: encoder) }
}

/// Configuration that checks what types cannot say, such as a count that must be positive, once it is decoded.
public protocol ValidatedConfiguration {
    /// Why the values cannot be used, one reason each naming its key; empty when they can.
    var problems: [String] { get }
}
