import Foundation

/// Front matter of a folder's `_about.md`: identity and a prose description. Folders are created on demand (by the
/// model's decisions or by the user); the model reads these descriptions, plus what the app has learned from usage,
/// to decide where documents belong. Where the folder sits in the tree is where its directory is, so it is not
/// written here. Keys are snake_case in YAML.
public struct FolderDefinition: Sendable, Codable, Hashable {
    /// Schema version of the `_about.md` format (`arrumator:` key). Written by the app.
    public var schema: Int?
    public var code: String
    public var name: String
    public var role: FolderRole?
    public var description: String
    public var yearSubfolders: Bool
    public var yearRule: YearRule?
    public var autoFile: Bool
    public var origin: FolderOrigin?
    /// What the folder stands for in the logic that made it (`LevelKind`); absent for folders the user made.
    public var kind: LevelKind?
    /// `LogicStore.version` of the logic that made the folder.
    public var logic: String?
    public var generatedHash: String?

    enum CodingKeys: String, CodingKey {
        case schema = "arrumator"
        case code, name, role, description
        case yearSubfolders = "year_subfolders"
        case yearRule = "year_rule"
        case autoFile = "auto_file"
        case origin, kind, logic
        case generatedHash = "generated_hash"
    }

    public init(code: String, name: String, role: FolderRole? = nil, description: String, yearSubfolders: Bool,
                yearRule: YearRule?, autoFile: Bool, origin: FolderOrigin?, kind: LevelKind? = nil, logic: String? = nil,
                schema: Int? = nil, generatedHash: String? = nil) {
        self.schema = schema
        self.code = code
        self.name = name
        self.role = role
        self.description = description
        self.yearSubfolders = yearSubfolders
        self.yearRule = yearRule
        self.autoFile = autoFile
        self.origin = origin
        self.kind = kind
        self.logic = logic
        self.generatedHash = generatedHash
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(FolderRole.self, forKey: .role)
        description = try c.decode(String.self, forKey: .description).trimmingCharacters(in: .whitespacesAndNewlines)
        yearSubfolders = try c.decode(Bool.self, forKey: .yearSubfolders)
        yearRule = try c.decodeIfPresent(YearRule.self, forKey: .yearRule)
        autoFile = try c.decode(Bool.self, forKey: .autoFile)
        origin = try c.decodeIfPresent(FolderOrigin.self, forKey: .origin)
        kind = try c.decodeIfPresent(LevelKind.self, forKey: .kind)
        logic = try c.decodeIfPresent(String.self, forKey: .logic)
        generatedHash = try c.decodeIfPresent(String.self, forKey: .generatedHash)
    }

    /// The folder's name from its directory's: the directory name itself, less the folder's own code where an earlier
    /// version put it in front (`11 Power of Attorney`).
    public func name(fromDirectory directoryName: String) -> String {
        directoryName.hasPrefix(code + " ") ? String(directoryName.dropFirst(code.count + 1)) : directoryName
    }
}

/// The app's identifiers for folders it creates: `F1`, `F2`, … never reused, so a record naming a folder that was
/// removed never comes to mean another one. Folders from earlier versions keep the codes they have.
public enum FolderCode {
    static let prefix = "F"

    /// The next free identifier after every one in `used`, removed folders' included.
    public static func next(after used: some Sequence<String>) -> String {
        let highest = used.compactMap { code in code.hasPrefix(prefix) ? Int(code.dropFirst(prefix.count)) : nil }.max() ?? 0
        return prefix + String(highest + 1)
    }
}

/// `YYYY` folders inside a folder, holding its documents of one year.
public enum YearFolder {
    public static func matches(_ name: String) -> Bool {
        name.wholeMatch(of: /(19|20)\d{2}/) != nil
    }
}
