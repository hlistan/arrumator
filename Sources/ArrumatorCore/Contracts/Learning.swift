import Foundation

public enum CorrectionSource: String, Sendable, Codable, CaseIterable {
    case review, reviewApprove, moveTo, finderMove, undo, bulkMove, markCorrect
}

/// A user decision that differs from (or confirms) what the app proposed.
public struct CorrectionEvent: Sendable, Codable {
    public var documentID: Int64
    public var source: CorrectionSource
    public var fromFolderID: Int64?
    public var toFolderID: Int64?
    public var fromFilename: String?
    public var toFilename: String?
    public var proposed: FilingDecision?
    public var editedFields: [String: String]
    public var traceID: Int64?
    public var at: Date

    public init(documentID: Int64, source: CorrectionSource, fromFolderID: Int64?, toFolderID: Int64?,
                fromFilename: String? = nil, toFilename: String? = nil, proposed: FilingDecision? = nil,
                editedFields: [String: String] = [:], traceID: Int64? = nil, at: Date = Date()) {
        self.documentID = documentID
        self.source = source
        self.fromFolderID = fromFolderID
        self.toFolderID = toFolderID
        self.fromFilename = fromFilename
        self.toFilename = toFilename
        self.proposed = proposed
        self.editedFields = editedFields
        self.traceID = traceID
        self.at = at
    }
}

/// A past filing remembered for kNN few-shot prompting.
public struct FilingMemory: Sendable, Codable, Identifiable, Hashable {
    public var id: Int64
    public var documentID: Int64
    public var folderID: Int64
    public var folderCode: String
    public var embedding: [Float]
    public var embeddingModel: String
    public var summaryLine: String
    public var correspondentID: Int64?
    public var documentType: DocumentType
    public var language: String
    public var stableKeys: [String]
    public var weight: Double
    public var source: String
    public var createdAt: Date

    public init(id: Int64, documentID: Int64, folderID: Int64, folderCode: String, embedding: [Float], embeddingModel: String,
                summaryLine: String, correspondentID: Int64?, documentType: DocumentType, language: String,
                stableKeys: [String], weight: Double, source: String, createdAt: Date) {
        self.id = id
        self.documentID = documentID
        self.folderID = folderID
        self.folderCode = folderCode
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.summaryLine = summaryLine
        self.correspondentID = correspondentID
        self.documentType = documentType
        self.language = language
        self.stableKeys = stableKeys
        self.weight = weight
        self.source = source
        self.createdAt = createdAt
    }
}

public enum RuleOrigin: String, Sendable, Codable {
    case user, induced, builtin
}

public enum RulePredicate: Sendable, Codable, Hashable {
    case correspondent(id: Int64)
    case stableKey(token: String)
    case textRegex(pattern: String)
    case filenameGlob(String)
    case utType(String)
    case emailSenderDomain(String)
    case whereFromDomain(String)
    case language(String)
    case documentType(DocumentType)

    /// Predicates that need the LLM's output and therefore run after it.
    public var isPostLLM: Bool {
        if case .documentType = self { return true }
        return false
    }

    /// The condition in words, the sender named by `sender`; a database id never reaches a reader.
    public func summary(sender: (Int64) -> String?) -> String {
        switch self {
        case let .correspondent(id): "from \(sender(id) ?? Self.forgottenSender)"
        case let .stableKey(token): "identifier \(token)"
        case let .textRegex(p): "text ~ /\(p)/"
        case let .filenameGlob(g): "filename \(g)"
        case let .utType(t): "type \(t)"
        case let .emailSenderDomain(d): "sender @\(d)"
        case let .whereFromDomain(d): "downloaded from \(d)"
        case let .language(l): "language \(l)"
        case let .documentType(t): "document type \(t.rawValue)"
        }
    }

    /// How a condition names a sender the app no longer knows.
    public static let forgottenSender = "a sender it has forgotten"
}

public struct RuleAction: Sendable, Codable, Hashable {
    public var folderID: Int64
    public var folderCode: String
    public var documentType: DocumentType?
    public var correspondentID: Int64?
    public var tags: [String]
    public var skipLLM: Bool

    public init(folderID: Int64, folderCode: String, documentType: DocumentType? = nil, correspondentID: Int64? = nil,
                tags: [String] = [], skipLLM: Bool = false) {
        self.folderID = folderID
        self.folderCode = folderCode
        self.documentType = documentType
        self.correspondentID = correspondentID
        self.tags = tags
        self.skipLLM = skipLLM
    }
}

public struct FilingRule: Sendable, Codable, Identifiable, Hashable {
    public var id: Int64
    public var name: String
    public var enabled: Bool
    public var priority: Int
    public var origin: RuleOrigin
    public var confirmed: Bool
    public var predicates: [RulePredicate]
    public var action: RuleAction
    /// Confirmed filings the rule was learned from.
    public var support: Int
    public var hits: Int
    public var contradictions: Int
    public var lastHitAt: Date?
    public var explanation: String
    /// The user told the app to forget this rule: it stays off and never forms again from the same evidence.
    public var forgotten: Bool
    public var createdAt: Date

    public init(id: Int64 = 0, name: String, enabled: Bool = true, priority: Int, origin: RuleOrigin,
                confirmed: Bool = false, predicates: [RulePredicate], action: RuleAction, support: Int = 0, hits: Int = 0,
                contradictions: Int = 0, lastHitAt: Date? = nil, explanation: String = "", forgotten: Bool = false,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.origin = origin
        self.confirmed = confirmed
        self.predicates = predicates
        self.action = action
        self.support = support
        self.hits = hits
        self.contradictions = contradictions
        self.lastHitAt = lastHitAt
        self.explanation = explanation
        self.forgotten = forgotten
        self.createdAt = createdAt
    }

    public var isPostLLM: Bool { predicates.contains(where: \.isPostLLM) }

    /// Share of independent evidence that agrees with the rule. Hits are uses of the rule, not evidence for it.
    /// A rule the user wrote counts as one piece of evidence in its own favour, so it is trusted until contradicted.
    public var reliability: Double {
        let agreeing = origin == .user ? max(support, 1) : support
        let total = Double(agreeing + contradictions)
        return total > 0 ? Double(agreeing) / total : 0
    }

    /// The sender the rule is about, when it names one. Rules the app forms are always about a sender.
    public var senderID: Int64? {
        predicates.lazy.compactMap { predicate -> Int64? in
            if case let .correspondent(id) = predicate { id } else { nil }
        }.first
    }

    /// When the rule applies, in words: "from EDP Comercial and document type invoice".
    public func condition(sender: (Int64) -> String?) -> String {
        predicates.map { $0.summary(sender: sender) }.joined(separator: " and ")
    }
}

public enum CorrespondentOrigin: String, Sendable, Codable {
    case learned, user
}

public struct Correspondent: Sendable, Codable, Identifiable, Hashable {
    public var id: Int64
    public var canonicalName: String
    public var country: String?
    /// Name variants seen in documents or entered by the user.
    public var aliases: [String]
    public var stableKeys: [String]
    public var emailDomains: [String]
    public var webDomains: [String]
    public var defaultFolderCode: String?
    public var filedCount: Int
    public var origin: CorrespondentOrigin

    public init(id: Int64 = 0, canonicalName: String, country: String? = nil, aliases: [String] = [],
                stableKeys: [String] = [], emailDomains: [String] = [], webDomains: [String] = [],
                defaultFolderCode: String? = nil, filedCount: Int = 0, origin: CorrespondentOrigin) {
        self.id = id
        self.canonicalName = canonicalName
        self.country = country
        self.aliases = aliases
        self.stableKeys = stableKeys
        self.emailDomains = emailDomains
        self.webDomains = webDomains
        self.defaultFolderCode = defaultFolderCode
        self.filedCount = filedCount
        self.origin = origin
    }

    /// Each sender's name by its id, for naming the senders in rule conditions.
    public static func names(_ senders: [Correspondent]) -> [Int64: String] {
        Dictionary(senders.map { ($0.id, $0.canonicalName) }, uniquingKeysWith: { first, _ in first })
    }
}

public enum ProposalKind: String, Sendable, Codable {
    case folderDescription, newFolder, rule, ruleDisabled
}

public enum ProposalStatus: String, Sendable, Codable {
    case pending, accepted, rejected
}

/// Persistence needed by classification and learning. `GRDBLearningStore` implements it over SQLite.
public protocol LearningStore: Sendable {
    func memories(model: String) async throws -> [FilingMemory]
    func memories(correspondentID: Int64) async throws -> [FilingMemory]
    func memories(folderID: Int64, limit: Int) async throws -> [FilingMemory]
    @discardableResult func insertMemory(_ memory: FilingMemory) async throws -> FilingMemory
    /// Deletes the document's memories and returns their ids.
    @discardableResult func deleteMemories(documentID: Int64) async throws -> [Int64]
    /// Raises the weight of a document's memories (e.g. when the user confirms a placement); returns them updated.
    @discardableResult func confirmMemories(documentID: Int64, weight: Double, source: String) async throws -> [FilingMemory]
    /// Raises memories of filings that have sat untouched since `before` to `weight`, and returns them. A filing the
    /// user never moved is evidence, even though they never said so.
    @discardableResult func settleMemories(before: Date, weight: Double, source: String) async throws -> [FilingMemory]
    /// Gives a document's memories a newly computed vector and returns them.
    @discardableResult func setMemoryEmbeddings(documentID: Int64, vector: [Float], model: String) async throws -> [FilingMemory]
    /// Keeps the newest `keep` memories of a folder, dropping low-weight ones first; returns removed ids.
    @discardableResult func pruneMemories(folderID: Int64, keep: Int) async throws -> [Int64]
    func setMemoriesOrphaned(folderID: Int64, orphaned: Bool) async throws

    func rules() async throws -> [FilingRule]
    @discardableResult func saveRule(_ rule: FilingRule) async throws -> FilingRule
    func recordRuleHit(ruleID: Int64, at: Date) async throws

    func correspondents() async throws -> [Correspondent]
    @discardableResult func saveCorrespondent(_ correspondent: Correspondent) async throws -> Correspondent

    @discardableResult func insertCorrection(_ correction: CorrectionEvent) async throws -> Int64
    func linkCorrespondent(documentID: Int64, correspondentID: Int64, name: String) async throws
    /// Correspondents whose trusted filings contain each identifier (an identifier shared by several correspondents,
    /// such as the user's own tax number, identifies none of them).
    func stableKeyOwners(minWeight: Double) async throws -> [String: Set<Int64>]
    /// What actually lives in a folder: recent file names and most frequent correspondents.
    func folderProfile(folderID: Int64, examples: Int, correspondents: Int) async throws -> LearnedBlock
    /// Removes a sender; its documents and filing examples keep their correspondent's name but lose the link.
    func deleteCorrespondent(id: Int64) async throws
    /// Which of these facts the app still knows.
    func known(_ facts: [LearnedFact]) async throws -> Set<LearnedFact>
    /// Filed documents in a folder, optionally only those from one correspondent or of one type.
    func documentCount(folderID: Int64, correspondentID: Int64?, documentType: DocumentType?) async throws -> Int
    /// Short text excerpts of documents (for description refresh prompts).
    func excerpts(documentIDs: [Int64], maxChars: Int) async throws -> [Int64: String]
    func meta(_ key: String) async throws -> String?
    func setMeta(_ key: String, _ value: String) async throws

    func folderEmbedding(folderID: Int64, model: String, descriptionHash: String) async throws -> [Float]?
    func saveFolderEmbedding(folderID: Int64, model: String, descriptionHash: String, vector: [Float]) async throws

    @discardableResult func createProposal(kind: ProposalKind, title: String, folderID: Int64?, payload: String) async throws -> Int64
    func hasPendingProposal(kind: ProposalKind, folderID: Int64?, title: String) async throws -> Bool
}

/// Payload of a `folderDescription` proposal: an LLM-drafted improvement of a folder's description.
public struct DescriptionProposal: Sendable, Codable, Hashable {
    public var folderID: Int64
    public var folderCode: String
    public var oldDescription: String
    public var newDescription: String
    public var examples: [String]
    public var basedOnDocuments: Int

    public init(folderID: Int64, folderCode: String, oldDescription: String, newDescription: String,
                examples: [String], basedOnDocuments: Int) {
        self.folderID = folderID
        self.folderCode = folderCode
        self.oldDescription = oldDescription
        self.newDescription = newDescription
        self.examples = examples
        self.basedOnDocuments = basedOnDocuments
    }
}

/// Payload of a `newFolder` proposal: a draft `_about.md` for a folder the user created without one.
public struct NewFolderProposal: Sendable, Codable, Hashable {
    public var folderID: Int64
    public var folderCode: String
    public var name: String
    public var description: String
    public var sampledFiles: [String]

    public init(folderID: Int64, folderCode: String, name: String, description: String, sampledFiles: [String]) {
        self.folderID = folderID
        self.folderCode = folderCode
        self.name = name
        self.description = description
        self.sampledFiles = sampledFiles
    }
}

/// Payload of `rule` / `ruleDisabled` proposals.
public struct RuleProposal: Sendable, Codable, Hashable {
    public var rule: FilingRule
    public var support: Int
    public var contradictions: Int

    public init(rule: FilingRule, support: Int, contradictions: Int) {
        self.rule = rule
        self.support = support
        self.contradictions = contradictions
    }
}

/// Something the app learned that the user can make it forget.
/// A document the app uses as an example of where documents like it go.
public struct LearnedExample: Sendable, Hashable, Identifiable {
    public var document: DocumentRecord
    public var memory: FilingMemory

    public init(document: DocumentRecord, memory: FilingMemory) {
        self.document = document
        self.memory = memory
    }

    public var id: Int64 { memory.documentID }
    /// What forgetting this example forgets.
    public var fact: LearnedFact { .example(documentID: memory.documentID) }
}

public enum LearnedFact: Sendable, Codable, Hashable {
    /// A filed document kept as an example of where documents like it go.
    case example(documentID: Int64)
    /// A rule. Once forgotten, it never forms again from the same evidence.
    case rule(id: Int64)
    /// Another name the user taught for a sender.
    case alias(correspondentID: Int64, alias: String)
    /// Everything known about a sender: names, identifiers, usual folder, and the rules about it.
    case sender(correspondentID: Int64)

    /// The fact a history event records, when it records one the user can forget.
    public static func recorded(by event: EventRecord) -> LearnedFact? {
        switch event.kind {
        case .learned: JSON.decode(LearnedFact.self, from: event.payloadJson)
        case .ruleInduced, .ruleChanged, .ruleDisabled: JSON.decode(RuleReference.self, from: event.payloadJson).map { .rule(id: $0.id) }
        default: nil
        }
    }

    /// Rule events carry the rule's summary; only its id matters here.
    private struct RuleReference: Decodable {
        var id: Int64
    }
}
