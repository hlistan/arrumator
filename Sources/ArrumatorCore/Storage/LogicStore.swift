import CryptoKit
import Foundation
import GRDB

/// The archive's logic: the prompt the model follows when it decides where documents go and what they are called.
/// Every archive has exactly one, kept in the archive itself (docs/storage.md), so two archives can be organised in
/// two different ways. Learned rules and past filings only advise it.
public struct LogicRecord: ArrumatorRecord, Hashable {
    public static let databaseTableName = "logic"
    /// The table's only row: an archive has one logic.
    public static let onlyID: Int64 = 1

    public var id: Int64 = Self.onlyID
    public var body: String
    /// The checksum of the built-in text the logic was last set from, or nil for logic the user wrote. While the
    /// body still has that checksum the logic follows the built-in text of each new version of the app; an edit, in
    /// the app or in the file, stops that.
    public var builtinHash: String?

    public init(body: String, builtinHash: String?) {
        self.body = body
        self.builtinHash = builtinHash
    }

    /// The logic is the built-in text, unchanged, and is kept up to date with the app.
    public var followsBuiltin: Bool { builtinHash == FrontMatter.sha256(body) }

    /// Space around a prompt means nothing, and the file adds a final newline; bodies are kept without it, so the text
    /// read back from the file is the text that was written.
    public static func normalized(_ body: String) -> String { body.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum LogicError: Error, LocalizedError {
    case tooLong(limit: Int)
    case unknownPlaceholders([String])
    case rethinkUnderWay

    public var errorDescription: String? {
        switch self {
        case let .tooLong(limit): "The logic is longer than \(limit) characters"
        case let .unknownPlaceholders(placeholders):
            "The logic refers to unknown values: \(placeholders.map { "{{\($0)}}" }.joined(separator: ", ")). "
                + "Only \(LogicStore.placeholders.sorted().map { "{{\($0)}}" }.joined(separator: ", ")) can be used"
        case .rethinkUnderWay: "A rethink is using the logic; apply or discard it before changing the logic"
        }
    }
}

/// The logic of the archive this index belongs to. Every change is recorded in the history.
public struct LogicStore: Sendable {
    /// Values logic may refer to as `{{name}}`; the prompt builder fills them in.
    public static let placeholders: Set<String> = ["folder_language"]

    public let database: AppDatabase
    /// Longest text logic may have, so it leaves room for the document in the model's context.
    public let maxChars: Int

    public init(database: AppDatabase, maxChars: Int) {
        self.database = database
        self.maxChars = maxChars
    }

    /// The logic the model follows; nil only for an index that has not been given one yet (see `sync`).
    public func current() async throws -> LogicRecord? {
        try await database.reader.read { db in try LogicRecord.fetchOne(db) }
    }

    /// Replaces the prompt. Editing it back to the built-in text it was set from makes it follow the app again.
    @discardableResult
    public func update(body: String) async throws -> LogicRecord {
        let body = LogicRecord.normalized(body)
        try validate(body)
        return try await database.writer.write { db in
            let existing = try LogicRecord.fetchOne(db)
            if let existing, existing.body == body { return existing }
            try Self.requireNoRethink(db)
            var logic = existing ?? LogicRecord(body: body, builtinHash: nil)
            logic.body = body
            try logic.save(db)
            try HistoryStore.insert(db, .logicChanged, actor: .user, summary: "Logic edited")
            return logic
        }
    }

    /// Restores the text that ships with the app, which the logic then follows.
    @discardableResult
    public func reset(to builtin: String) async throws -> LogicRecord {
        let builtin = LogicRecord.normalized(builtin)
        return try await database.writer.write { db in
            try Self.requireNoRethink(db)
            var logic = LogicRecord(body: builtin, builtinHash: FrontMatter.sha256(builtin))
            try logic.save(db)
            try HistoryStore.insert(db, .logicChanged, actor: .user, summary: "Logic reset to the original")
            return logic
        }
    }

    /// Gives an archive without logic the built-in text, and keeps logic that still follows it up to date with this
    /// version of the app.
    public func sync(builtin: String) async throws {
        let builtin = LogicRecord.normalized(builtin)
        try await database.writer.write { db in
            let hash = FrontMatter.sha256(builtin)
            guard var logic = try LogicRecord.fetchOne(db) else {
                var first = LogicRecord(body: builtin, builtinHash: hash)
                try first.insert(db)
                return
            }
            guard logic.followsBuiltin, logic.builtinHash != hash else { return }
            logic.body = builtin
            logic.builtinHash = hash
            try logic.update(db)
            try HistoryStore.insert(db, .logicChanged, summary: "Logic updated with this version of Arrumator")
        }
    }

    /// A short fingerprint of the prompt, recorded with every decision so it is clear what made it.
    public static func version(of logic: LogicRecord?) -> String {
        guard let logic else { return "none" }
        return SHA256.hash(data: Data(logic.body.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Changing the logic while a rethink is planned would mix two kinds of logic in one plan.
    private static func requireNoRethink(_ db: Database) throws {
        let active = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rethink_runs WHERE status IN (?, ?, ?)",
                                      arguments: [RethinkRunStatus.planning.rawValue, RethinkRunStatus.ready.rawValue,
                                                  RethinkRunStatus.applying.rawValue]) ?? 0
        guard active == 0 else { throw LogicError.rethinkUnderWay }
    }

    func validate(_ body: String) throws {
        guard body.count <= maxChars else { throw LogicError.tooLong(limit: maxChars) }
        let used = Set(body.matches(of: /\{\{([a-z_]+)\}\}/).map { String($0.1) })
        let unknown = used.subtracting(Self.placeholders)
        guard unknown.isEmpty else { throw LogicError.unknownPlaceholders(unknown.sorted()) }
    }
}
