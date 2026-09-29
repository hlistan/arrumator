import ArrumatorCore
import Foundation

/// Learns who documents come from. Every filed document is linked to its sender, a known one or a new one, and the
/// identifiers that are only ever on one sender's documents become that sender's own, so its next document is
/// recognised by them however its name is written. A sender the user renames keeps the old name as another one.
public actor SenderLearner: LearningSink {
    private let store: SenderStore
    private let config: SendersConfig
    private let history: HistoryStore

    public init(store: SenderStore, config: SendersConfig, history: HistoryStore) {
        self.store = store
        self.config = config
        self.history = history
    }

    public func documentFiled(documentID: Int64, analysis: DocumentAnalysis, content: ExtractedContent, trace: TraceContext) async {
        do {
            let started = Date()
            guard let sender = try await link(documentID: documentID, analysis: analysis, content: content) else { return }
            try await learnIdentifiers(sender)
            await trace.record(.learn, startedAt: started, input: ["sender": sender.canonicalName])
        } catch {
            Log.error(.learn, "Could not learn from filing", ["doc": String(documentID), "error": error.localizedDescription])
        }
    }

    public func senderRenamed(documentID: Int64, from: String, to: String) async {
        do {
            let norm = TextNormalizer.normalize
            guard norm(from) != norm(to) else { return }
            let all = try await store.correspondents()
            var target = all.first { norm($0.canonicalName) == norm(to) } ?? Correspondent(canonicalName: to, origin: .user)
            if !target.aliases.contains(where: { norm($0) == norm(from) }) {
                target.aliases.append(from)
                target = try await store.saveCorrespondent(target)
                try await history.record(.learned, doc: documentID, summary: "Remembered “\(from)” as another name for \(target.canonicalName)",
                                         payload: LearnedFact.alias(correspondentID: target.id, alias: from))
            } else {
                target = try await store.saveCorrespondent(target)
            }
            try await store.linkCorrespondent(documentID: documentID, correspondentID: target.id, name: target.canonicalName)
            try await learnIdentifiers(target)
        } catch {
            Log.error(.learn, "Could not learn another name for a sender", ["error": error.localizedDescription])
        }
    }

    public func documentForgotten(documentID: Int64) async {
        do {
            for sender in try await store.correspondents() { try await learnIdentifiers(sender) }
        } catch {
            Log.error(.learn, "Could not learn senders again", ["doc": String(documentID), "error": error.localizedDescription])
        }
    }

    // MARK: Forgetting

    /// Makes the app forget something it learned, and records that it did. Forgetting what is already forgotten
    /// does nothing.
    public func forget(_ fact: LearnedFact) async throws {
        let summary: String
        switch fact {
        case let .alias(correspondentID, alias):
            guard var sender = try await store.correspondents().first(where: { $0.id == correspondentID }),
                  sender.aliases.contains(alias) else { return }
            sender.aliases.removeAll { $0 == alias }
            try await store.saveCorrespondent(sender)
            summary = "Forgot that “\(alias)” is another name for \(sender.canonicalName)"
        case let .sender(correspondentID):
            guard let sender = try await store.correspondents().first(where: { $0.id == correspondentID }) else { return }
            try await store.deleteCorrespondent(id: correspondentID)
            summary = "Forgot what it knew about \(sender.canonicalName)"
        }
        try await history.record(.forgot, actor: .user, summary: summary, payload: fact)
        Log.info(.learn, "Forgot", ["what": summary])
    }

    // MARK: Senders

    /// Links the document to the sender its analysis names: the known one it was recognised as, one known by that
    /// name or another name, or a new one.
    private func link(documentID: Int64, analysis: DocumentAnalysis, content: ExtractedContent) async throws -> Correspondent? {
        let all = try await store.correspondents()
        if let id = analysis.correspondentID, let known = all.first(where: { $0.id == id }) {
            try await store.linkCorrespondent(documentID: documentID, correspondentID: known.id, name: known.canonicalName)
            return known
        }
        guard let name = analysis.correspondent?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let normalized = TextNormalizer.normalize(name)
        if let existing = all.first(where: { c in ([c.canonicalName] + c.aliases).contains { TextNormalizer.normalize($0) == normalized } }) {
            try await store.linkCorrespondent(documentID: documentID, correspondentID: existing.id, name: existing.canonicalName)
            return existing
        }
        let emailDomain = content.metadata["email:from"].flatMap(CorrespondentResolver.domain(ofEmail:))
        let created = try await store.saveCorrespondent(Correspondent(
            canonicalName: name, emailDomains: emailDomain.map { [$0] } ?? [], origin: .learned))
        try await store.linkCorrespondent(documentID: documentID, correspondentID: created.id, name: created.canonicalName)
        Log.info(.learn, "Learned new sender", ["name": name])
        return created
    }

    /// Makes the identifiers seen on at least `stableKeyMinFilings` of the sender's filed documents, and on no other
    /// sender's, the sender's own. One that turns up on another sender's documents (the user's own tax number or IBAN,
    /// printed on every bill) identifies neither, and every sender that had it loses it.
    private func learnIdentifiers(_ correspondent: Correspondent) async throws {
        let bySender = try await store.identifiersBySender()
        let owners = bySender.reduce(into: [String: Set<Int64>]()) { owners, entry in
            for token in entry.value.keys { owners[token, default: []].insert(entry.key) }
        }
        let shared = Set(owners.filter { $0.value.count > 1 }.keys)
        let counts = bySender[correspondent.id] ?? [:]
        let promoted = counts.filter { $0.value >= config.stableKeyMinFilings && !shared.contains($0.key) }.map(\.key)
        for sender in try await store.correspondents() {
            var c = sender
            c.stableKeys = c.stableKeys.filter { !shared.contains($0) }
            if sender.id == correspondent.id {
                c.stableKeys = Array(Set(c.stableKeys + promoted)).sorted()
                c.filedCount = try await store.filedCount(correspondentID: sender.id)
            }
            if c != sender { try await store.saveCorrespondent(c) }
        }
    }
}
