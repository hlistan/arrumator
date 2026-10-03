import Foundation
import GRDB

/// Record files as read from disk, ready to apply to the index in one transaction.
struct ParsedRecords: Sendable {
    var documents: [(directory: URL, entries: [DocumentEntry])] = []
    var history: [(month: String, entries: [EventEntry])] = []
    var labelRules: [LabelRuleEntry]?
    var searchTasks: [SearchTaskEntry]?
    var conversations: [(task: Int64, url: URL, entries: [ConversationTurnEntry])] = []
    /// The checksum of each file read, by its path.
    var hashes: [String: String] = [:]

    init() {}

    /// The record file of `kind` at `url`, whose text is `text`. Throws `RecordsError.unreadable`, saying why without
    /// quoting the file, for one whose front matter the app does not read.
    init(_ kind: RecordKind, url: URL, text: String) throws {
        func list<Entry: Decodable & Sendable>(_ type: Entry.Type) throws -> [Entry] {
            do {
                return try FrontMatter.read(RecordList<Entry>.self, from: text, path: url.path).value.entries
            } catch let error as FrontMatterError {
                throw RecordsError.unreadable(url.path, error.reason)
            } catch {
                throw RecordsError.unreadable(url.path, error.localizedDescription)
            }
        }
        switch kind {
        case .documents:
            let entries = try list(DocumentEntry.self)
            if let index = entries.firstIndex(where: { !$0.namesOneFile }) {
                throw RecordsError.unreadable(url.path, "entries[\(index)].file is not the name of one file in its folder")
            }
            documents = [(url.deletingLastPathComponent(), entries)]
        case let .history(month):
            let lines = try list(HistoryLine.self)
            let events = lines.compactMap(\.event)
            history = [(month, events)]
            if events.count < lines.count {
                Log.info(.db, "History events of kinds that no longer exist dropped, as migrating the index dropped them",
                         ["path": url.path, "events": String(lines.count - events.count)])
            }
        case .labelRules: labelRules = try list(LabelRuleEntry.self)
        case .searchTasks: searchTasks = try list(SearchTaskEntry.self)
        case let .conversation(task): conversations = [(task, url, try list(ConversationTurnEntry.self))]
        }
        hashes[url.path] = FrontMatter.sha256(text)
    }

    mutating func merge(_ other: ParsedRecords) {
        documents += other.documents
        history += other.history
        labelRules = other.labelRules ?? labelRules
        searchTasks = other.searchTasks ?? searchTasks
        conversations += other.conversations
        hashes.merge(other.hashes) { _, new in new }
    }

    /// What the index keeps of its own about an event, which its history file does not hold: the job and the trace it
    /// was recorded with.
    struct EventLink: Sendable {
        var kind: EventKind
        var job: Int64?
        var trace: Int64?
    }

    /// The links of the events of the months these files hold, or of every event when `everyMonth`, taken before what the
    /// files say replaces the events.
    func eventLinks(_ db: Database, everyMonth: Bool) throws -> [Int64: EventLink] {
        let months = history.map(\.month)
        guard everyMonth || !months.isEmpty else { return [:] }
        let inMonths = everyMonth ? "" : " AND strftime('%Y-%m', at, 'unixepoch') IN (\(months.map { _ in "?" }.joined(separator: ",")))"
        let rows = try Row.fetchAll(db, sql: "SELECT id, kind, job_id, trace_id FROM events WHERE (job_id IS NOT NULL OR trace_id IS NOT NULL)" + inMonths,
                                    arguments: StatementArguments(everyMonth ? [] : months))
        return Dictionary(rows.compactMap { row in
            EventKind(rawValue: row["kind"]).map { (row["id"] as Int64, EventLink(kind: $0, job: row["job_id"], trace: row["trace_id"])) }
        }, uniquingKeysWith: { a, _ in a })
    }

    /// What applying the records came to.
    struct Applied {
        /// The lists of documents to write again.
        var rewrite: Set<RecordKind> = []
        /// Files read but not taken into the index, by path: their checksums are not remembered, so they are never
        /// written over as though the index held what they hold.
        var notTakenIn: Set<String> = []
    }

    /// Puts the records into the index. The lists of documents to write again are those of the directories read, or of
    /// every directory when `everyDirectory`, where the index has a document no list read names, and those whose entries
    /// were given numbers of their own. Documents are only ever added or updated here: an entry missing from a file does
    /// not delete a document, whose entry is written back instead. Other files replace their table when `replacing`, and
    /// otherwise add and update their rows. An event keeps the job and trace in `links` when it is the same event. A
    /// conversation about a task the index does not have is not taken in.
    func apply(to db: Database, replacing: Bool, at now: Date, links: [Int64: EventLink], everyDirectory: Bool) throws -> Applied {
        var applied = Applied()
        let (listed, renumbered) = try applyDocuments(db, at: now)
        for (month, entries) in history {
            if replacing {
                try db.execute(sql: "DELETE FROM events WHERE strftime('%Y-%m', at, 'unixepoch') = ? AND id NOT IN (\(ArchiveRecords.ids(entries.map(\.id))))",
                               arguments: [month])
            }
            for entry in entries {
                var record = entry.record
                if let link = links[entry.id], link.kind == entry.kind {
                    record.jobId = link.job
                    record.traceId = link.trace
                }
                if let doc = record.docId, try !DocumentRecord.exists(db, key: doc) { record.docId = nil }
                try record.save(db)
            }
        }
        if let labelRules {
            if replacing {
                try db.execute(sql: "DELETE FROM label_rules WHERE id NOT IN (\(ArchiveRecords.ids(labelRules.map(\.id))))")
            }
            for entry in labelRules {
                var record = entry.record
                try record.save(db)
            }
        }
        if let searchTasks {
            if replacing {
                try db.execute(sql: "DELETE FROM search_tasks WHERE id NOT IN (\(ArchiveRecords.ids(searchTasks.map(\.id))))")
            }
            for entry in searchTasks { try SearchTaskStore.restore(entry, db: db) }
        }
        // After the tasks, whose conversations they are.
        applied.notTakenIn = try applyConversations(db, replacing: replacing)
        applied.rewrite = renumbered
        if everyDirectory || !documents.isEmpty {
            applied.rewrite.formUnion(try Self.unlisted(db, listed: listed, in: everyDirectory ? nil : documents.map(\.directory)))
        }
        return applied
    }

    /// Adds or updates every document listed, and returns the numbers of their documents in the index and the lists
    /// whose entries were given numbers of their own.
    private func applyDocuments(_ db: Database, at now: Date) throws -> (listed: Set<Int64>, renumbered: Set<RecordKind>) {
        var listed: Set<Int64> = []
        var renumbered: Set<RecordKind> = []
        for (directory, entries) in documents {
            // Each entry's number in its list, and the number of its document in the index.
            var numbers: [Int64: Int64] = [:]
            for entry in entries {
                let id = try Self.upsert(entry, directory: directory, db: db, at: now)
                listed.insert(id)
                numbers[entry.id] = id
                if id != entry.id { renumbered.insert(.documents(directory: directory.path)) }
            }
            // A list renumbered on reading counts by another archive's numbers: a copy in it is of the document it lists
            // under that number, or, when it lists none, of one of that archive's, which is nothing here.
            guard renumbered.contains(.documents(directory: directory.path)) else { continue }
            for entry in entries {
                guard let original = entry.duplicateOf, let id = numbers[entry.id], numbers[original] != original else { continue }
                try db.execute(sql: "UPDATE documents SET duplicate_of = ? WHERE id = ?", arguments: [numbers[original], id])
            }
        }
        // A copy of a document the archive does not have is a copy of nothing, as an event about one is about nothing.
        try db.execute(sql: """
            UPDATE documents SET duplicate_of = NULL
            WHERE id IN (\(ArchiveRecords.ids(Array(listed)))) AND duplicate_of IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM documents original WHERE original.id = documents.duplicate_of)
            """)
        return (listed, renumbered)
    }

    /// Adds or updates the questions of each conversation about a task the index has, and returns the files of those
    /// about one it does not have, which are not taken in. Such a file is left where it is and read again until its task
    /// is back, its number given to no new task meanwhile, as the questions in it would be taken for that one's
    /// (https://sqlite.org/autoinc.html: the sequence may be changed by ordinary statements).
    private func applyConversations(_ db: Database, replacing: Bool) throws -> Set<String> {
        var notTakenIn: Set<String> = []
        for (task, url, entries) in conversations {
            guard try SearchTaskRecord.exists(db, key: task) else {
                notTakenIn.insert(url.path)
                try db.execute(sql: "UPDATE sqlite_sequence SET seq = ? WHERE name = ? AND seq < ?",
                               arguments: [task, SearchTaskRecord.databaseTableName, task])
                try db.execute(sql: "INSERT INTO sqlite_sequence (name, seq) SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = ?)",
                               arguments: [SearchTaskRecord.databaseTableName, task, SearchTaskRecord.databaseTableName])
                continue
            }
            try TaskConversationStore.restore(entries, task: task, replacing: replacing, db: db)
        }
        return notTakenIn
    }

    /// The lists of the directories, of `directories` or of all when nil, where the index has a document no list read
    /// names: its entry, removed by hand or never written, is written back.
    private static func unlisted(_ db: Database, listed: Set<Int64>, in directories: [URL]?) throws -> Set<RecordKind> {
        let directory = "rtrim(path, replace(path, '/', ''))"
        let within = directories.map { " AND \(directory) IN (\($0.map { _ in "?" }.joined(separator: ",")))" } ?? ""
        let found = try String.fetchAll(db, sql: "SELECT DISTINCT \(directory) FROM documents WHERE id NOT IN (\(ArchiveRecords.ids(Array(listed))))" + within,
                                        arguments: StatementArguments((directories ?? []).map { $0.path + "/" }))
        return Set(found.compactMap { RecordKind(key: RecordKind.documentsPrefix + $0) })
    }

    /// Adds or updates a document from its entry, keeping what the index caches about the file, and returns its number.
    /// A document is the one its identity names: an entry whose number the index gives another document, as in a folder
    /// copied in from another archive whose numbers also start at 1, is taken in under a number of its own.
    private static func upsert(_ entry: DocumentEntry, directory: URL, db: Database, at now: Date) throws -> Int64 {
        var record = try entry.record(directory: directory, now: now)
        if let existing = try DocumentRecord.filter(Column("uid") == entry.uid).fetchOne(db) {
            record.id = existing.id
            record.inode = existing.inode
            record.contentJson = existing.contentJson
            record.extractedAt = existing.extractedAt
            record.embeddedAt = existing.embeddedAt
            record.fileMtime = existing.fileMtime
            record.lastTraceId = existing.lastTraceId
            record.createdAt = existing.createdAt
            try record.update(db)
        } else {
            if try DocumentRecord.exists(db, key: entry.id) { record.id = nil }
            try record.insert(db)
        }
        return record.id ?? entry.id
    }
}
