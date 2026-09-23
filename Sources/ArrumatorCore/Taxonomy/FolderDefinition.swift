import Foundation

/// Front matter of a folder's `_about.md`: structure and a prose description only. Folders are created on demand
/// (by the model's decisions or by the user); the model reads these descriptions, plus what the app has learned
/// from usage, to decide where documents belong. Keys are snake_case in YAML.
public struct FolderDefinition: Sendable, Codable, Hashable {
    /// Schema version of the `_about.md` format (`arrumator:` key). Written by the app.
    public var schema: Int?
    public var code: String
    public var area: String?
    public var name: String
    public var role: FolderRole?
    public var description: String
    public var yearSubfolders: Bool
    public var yearRule: YearRule?
    public var autoFile: Bool
    public var origin: FolderOrigin?
    public var generatedHash: String?

    enum CodingKeys: String, CodingKey {
        case schema = "arrumator"
        case code, area, name, role, description
        case yearSubfolders = "year_subfolders"
        case yearRule = "year_rule"
        case autoFile = "auto_file"
        case origin
        case generatedHash = "generated_hash"
    }

    public init(code: String, area: String?, name: String, role: FolderRole? = nil, description: String, yearSubfolders: Bool,
                yearRule: YearRule?, autoFile: Bool, origin: FolderOrigin?, schema: Int? = nil, generatedHash: String? = nil) {
        self.schema = schema
        self.code = code
        self.area = area
        self.name = name
        self.role = role
        self.description = description
        self.yearSubfolders = yearSubfolders
        self.yearRule = yearRule
        self.autoFile = autoFile
        self.origin = origin
        self.generatedHash = generatedHash
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema)
        code = try c.decode(String.self, forKey: .code)
        area = try c.decodeIfPresent(String.self, forKey: .area)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(FolderRole.self, forKey: .role)
        description = try c.decode(String.self, forKey: .description).trimmingCharacters(in: .whitespacesAndNewlines)
        yearSubfolders = try c.decode(Bool.self, forKey: .yearSubfolders)
        yearRule = try c.decodeIfPresent(YearRule.self, forKey: .yearRule)
        autoFile = try c.decode(Bool.self, forKey: .autoFile)
        origin = try c.decodeIfPresent(FolderOrigin.self, forKey: .origin)
        generatedHash = try c.decodeIfPresent(String.self, forKey: .generatedHash)
    }

    public var kind: FolderKind { JDCode.isArea(code) ? .area : .category }
    /// Folder name on disk: `20-29 Money & taxes`, `23 Taxes (Portugal)`.
    public var directoryName: String { "\(code) \(name)" }
}

/// Johnny.Decimal code helpers.
public enum JDCode {
    /// `"20-29"`
    public static func isArea(_ code: String) -> Bool {
        code.wholeMatch(of: /\d{2}-\d{2}/) != nil
    }

    /// `"23"`
    public static func isCategory(_ code: String) -> Bool {
        code.wholeMatch(of: /\d{2}/) != nil
    }

    /// A name written the way its directory is named, "10-19 Insurance & Legal" or "11 Power of Attorney", split into
    /// code and name. Models echo names so from the folder tree they are shown, though codes are the app's to assign.
    /// The code must be followed by a space, so a name that merely starts with digits ("2025 Taxes") is no echo.
    public static func echoedCode(in name: String) -> (code: String, name: String)? {
        guard let m = name.wholeMatch(of: /(\d{2}-\d{2}|\d{2})\s+(.+)/) else { return nil }
        return (String(m.1), String(m.2).trimmingCharacters(in: .whitespaces))
    }

    /// Area code that contains a category code: `"23"` → `"20-29"`.
    public static func area(of category: String) -> String? {
        guard isCategory(category), let n = Int(category) else { return nil }
        let start = n / 10 * 10
        return String(format: "%02d-%02d", start, start + 9)
    }

    /// Category range of an area: `"20-29"` → 21...29 (the `x0` slot is reserved by Johnny.Decimal convention).
    public static func categoryRange(of area: String) -> ClosedRange<Int>? {
        let parts = area.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts[0] < parts[1] else { return nil }
        return (parts[0] + 1)...parts[1]
    }

    /// First unused category code inside `area`.
    public static func nextFreeCategory(in area: String, used: Set<String>) -> String? {
        guard let range = categoryRange(of: area) else { return nil }
        return range.map { String(format: "%02d", $0) }.first { !used.contains($0) }
    }

    /// First unused area code (`"10-19"`, `"20-29"`, …) between `first` and `last` (decade starts).
    public static func nextFreeArea(used: Set<String>, first: Int, last: Int) -> String? {
        stride(from: first, through: last, by: 10).map { String(format: "%02d-%02d", $0, $0 + 9) }.first { !used.contains($0) }
    }

    /// Parses a directory name like `23 Taxes (Portugal)` or `20-29 Money` into (code, name).
    public static func parse(directoryName: String) -> (code: String, name: String)? {
        guard let m = directoryName.wholeMatch(of: /(\d{2}(?:-\d{2})?)\s*[-–—]?\s*(.+)/) else { return nil }
        return (String(m.1), String(m.2).trimmingCharacters(in: .whitespaces))
    }

    /// A `YYYY` year folder.
    public static func isYearFolder(_ name: String) -> Bool {
        name.wholeMatch(of: /(19|20)\d{2}/) != nil
    }
}
