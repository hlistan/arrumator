import Foundation

public enum ConfigError: Error, LocalizedError {
    case missingResource(String)
    case invalid(name: String, underlying: String)
    /// The configuration `name` the files at `paths` give cannot be used, for `underlying`; `mend` says how to mend it.
    case invalidFile(name: String, paths: [String], underlying: String, mend: String)

    public var errorDescription: String? {
        switch self {
        case let .missingResource(name): "Bundled configuration \(name) is missing"
        case let .invalid(name, underlying): "Configuration \(name) is invalid: \(underlying)"
        case let .invalidFile(name, paths, underlying, mend):
            "Configuration \(name) in \(paths.joined(separator: " and ")) is invalid: \(underlying). \(mend)"
        }
    }

    /// The same refusal, saying which files give the configuration and how to mend it; a refusal of another kind, as it is.
    func naming(_ paths: [URL], mend: String) -> ConfigError {
        guard case let .invalid(name, underlying) = self, !paths.isEmpty else { return self }
        return .invalidFile(name: name, paths: paths.map(\.path), underlying: underlying, mend: mend)
    }
}

/// Loads strongly typed configuration from bundled JSON defaults, deep-merged with an optional user override file.
/// The bundled file is the single source of every default; Swift types declare no default values. A key the app does
/// not read stops the load, naming it, rather than being ignored: a key an earlier version wrote, such as a choice it
/// kept elsewhere, is never read as something else or silently dropped (AGENTS.md §4.2).
public enum ConfigLoader {
    public static func bundledValue(_ name: String) throws -> JSONValue {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Defaults") else {
            throw ConfigError.missingResource("\(name).json")
        }
        return try JSON.decoder.decode(JSONValue.self, from: Data(contentsOf: url))
    }

    /// - Parameter validating: whether what the configuration's `problems` say refuses it too; a key the app does not know
    ///   always does. Only what mends the configuration loads it without, and refuses what it leaves (`SettingsStore`).
    public static func load<T: Codable>(_ type: T.Type, defaults name: String, overrides: [JSONValue] = [], validating: Bool = true) throws -> T {
        let bundled = try bundledValue(name)
        var merged = bundled
        for o in overrides { merged = deepMerge(merged, o) }
        let value: T
        let read: JSONValue
        do {
            value = try JSON.decoder.decode(T.self, from: JSON.encoder.encode(merged))
            // What the app reads of the configuration: the value it decoded, written out again.
            read = try JSON.decoder.decode(JSONValue.self, from: JSON.encoder.encode(value))
        } catch {
            throw ConfigError.invalid(name: name, underlying: String(describing: error))
        }
        let unknown = Set(([bundled] + overrides).flatMap { unknownKeys(in: $0, read: read) }).sorted()
        let problems = validating ? (value as? any ValidatedConfiguration)?.problems ?? [] : []
        try refuse(unknown.map(unknownKey) + problems, name: name)
        return value
    }

    /// Stops with `problems`, the reasons the configuration `name` cannot be used, when there are any.
    static func refuse(_ problems: [String], name: String) throws {
        guard problems.isEmpty else { throw ConfigError.invalid(name: name, underlying: problems.joined(separator: "; ")) }
    }

    /// Stops as `refuse(_:name:)` does, naming the settings file at `file` and how to mend it.
    static func refuse(_ problems: [String], name: String, file: URL, mend: String = SettingsStore.mend) throws {
        do { try refuse(problems, name: name) } catch let refused as ConfigError {
            throw refused.naming([file], mend: mend)
        }
    }

    /// Why a configuration with the key at `path` is refused.
    public static func unknownKey(_ path: String) -> String { "\(path) is not a key the app knows; remove it" }

    /// The dotted paths of the keys `value` sets, at any depth, that `read` does not have. Objects are walked key by key,
    /// so a key the user gave a dictionary of free keys (Ollama's variables, a profile of the user's) is known once it is
    /// read; an array or any other value is taken whole, and a null sets nothing (`deepMerge`).
    static func unknownKeys(in value: JSONValue, read: JSONValue, at path: String = "") -> [String] {
        guard case let .object(set) = value, case let .object(known) = read else { return [] }
        return set.flatMap { key, sub -> [String] in
            if case .null = sub { return [] }
            let keyPath = path.isEmpty ? key : "\(path).\(key)"
            guard let readSub = known[key] else { return [keyPath] }
            return unknownKeys(in: sub, read: readSub, at: keyPath)
        }
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
