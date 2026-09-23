import Foundation

public enum ProposalError: Error, LocalizedError {
    case notFound(Int64)
    case alreadyResolved(Int64)
    case unreadablePayload(Int64)

    public var errorDescription: String? {
        switch self {
        case let .notFound(id): "Proposal \(id) does not exist"
        case let .alreadyResolved(id): "Proposal \(id) was already resolved"
        case let .unreadablePayload(id): "Proposal \(id) has an unreadable payload"
        }
    }
}

/// Applies or rejects what the learner proposed: description improvements, drafts for user folders and rules.
public struct ProposalActions: Sendable {
    public let database: AppDatabase
    public let taxonomy: TaxonomyStore
    public let settings: SettingsStore

    public init(database: AppDatabase, taxonomy: TaxonomyStore, settings: SettingsStore) {
        self.database = database
        self.taxonomy = taxonomy
        self.settings = settings
    }

    private var store: GRDBLearningStore { GRDBLearningStore(database: database) }

    public func pending() async throws -> [ProposalRecord] { try await store.proposals(status: .pending) }

    public func accept(_ id: Int64) async throws {
        let proposal = try await load(id)
        let root = await settings.current.archiveURL
        switch ProposalKind(rawValue: proposal.kind) {
        case .folderDescription:
            guard let p = JSON.decode(DescriptionProposal.self, from: proposal.payloadJson) else { throw ProposalError.unreadablePayload(id) }
            let (about, _) = try await currentAbout(folderID: p.folderID, root: root)
            var def = about.definition
            def.description = p.newDescription
            try await taxonomy.updateDescription(folderID: p.folderID, root: root, definition: def, body: about.body, actor: .system)
        case .newFolder:
            guard let p = JSON.decode(NewFolderProposal.self, from: proposal.payloadJson) else { throw ProposalError.unreadablePayload(id) }
            let (about, record) = try await currentAbout(folderID: p.folderID, root: root)
            var def = about.definition
            def.description = p.description
            def.autoFile = true
            def.origin = .learned
            let body = about.body.isEmpty ? "# \(record.code) \(record.name)\n\n\(p.description)" : about.body
            try await taxonomy.updateDescription(folderID: p.folderID, root: root, definition: def, body: body, actor: .system)
        case .rule:
            guard var p = JSON.decode(RuleProposal.self, from: proposal.payloadJson) else { throw ProposalError.unreadablePayload(id) }
            p.rule.enabled = true
            p.rule.confirmed = true
            try await store.saveRule(p.rule)
        case .ruleDisabled:
            guard var p = JSON.decode(RuleProposal.self, from: proposal.payloadJson) else { throw ProposalError.unreadablePayload(id) }
            p.rule.enabled = true
            p.rule.contradictions = 0
            try await store.saveRule(p.rule)
        case .none:
            throw ProposalError.unreadablePayload(id)
        }
        try await store.resolveProposal(id: id, status: .accepted)
        Log.info(.learn, "Proposal accepted", ["id": String(id), "kind": proposal.kind])
    }

    public func reject(_ id: Int64) async throws {
        _ = try await load(id)
        try await store.resolveProposal(id: id, status: .rejected)
        Log.info(.learn, "Proposal rejected", ["id": String(id)])
    }

    private func load(_ id: Int64) async throws -> ProposalRecord {
        guard let p = try await database.reader.read({ db in try ProposalRecord.fetchOne(db, key: id) }) else {
            throw ProposalError.notFound(id)
        }
        guard p.status == ProposalStatus.pending.rawValue else { throw ProposalError.alreadyResolved(id) }
        return p
    }

    private func currentAbout(folderID: Int64, root: URL) async throws -> (AboutFile, FolderRecord) {
        guard let record = try await database.reader.read({ db in try FolderRecord.fetchOne(db, key: folderID) }) else {
            throw TaxonomyError.unknownFolder(folderID)
        }
        let url = await taxonomy.aboutURL(for: record, root: root)
        if let about = try? await taxonomy.readAbout(url) { return (about, record) }
        let def = FolderDefinition(code: record.code, area: JDCode.area(of: record.code), name: record.name,
                                   description: record.description, yearSubfolders: record.yearSubfolders,
                                   yearRule: YearRule(rawValue: record.yearRule), autoFile: record.autoFile,
                                   origin: FolderOrigin(rawValue: record.origin))
        return (AboutFile(definition: def, body: ""), record)
    }
}
