import ArrumatorCore
import Foundation

/// Asks the local model to improve a folder's description from what is actually stored there, and files the
/// result as a proposal for the user to accept.
public struct DescriptionRefresher: Sendable {
    public let store: any LearningStore
    public let gate: InferenceGate
    public let library: PromptLibrary
    public let config: LearningConfig.DescriptionRefresh

    public init(store: any LearningStore, gate: InferenceGate, library: PromptLibrary, config: LearningConfig.DescriptionRefresh) {
        self.store = store
        self.gate = gate
        self.library = library
        self.config = config
    }

    static func counterKey(_ folderID: Int64) -> String { "description_refresh_count_\(folderID)" }
    static func lastRunKey(_ folderID: Int64) -> String { "description_refresh_at_\(folderID)" }

    /// Counts a confirmed filing and returns true when the folder is due for a refresh.
    public func noteFiling(folderID: Int64, now: Date = Date()) async throws -> Bool {
        let count = (Int(try await store.meta(Self.counterKey(folderID)) ?? "0") ?? 0) + 1
        try await store.setMeta(Self.counterKey(folderID), String(count))
        let last = try await store.meta(Self.lastRunKey(folderID)).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let intervalOver = last.map { now.timeIntervalSince($0) >= config.intervalDays * 86_400 } ?? true
        return count >= config.minNewDocuments && intervalOver
    }

    @discardableResult
    public func propose(folder: TaxonomyFolder, taxonomy: TaxonomySnapshot, model: String, keepAlive: String,
                        numCtx: Int, language: String) async throws -> Int64? {
        let memories = try await store.memories(folderID: folder.id, limit: config.sampleSize)
        guard !memories.isEmpty else { return nil }
        let excerpts = try await store.excerpts(documentIDs: Array(memories.prefix(config.excerptSamples).map(\.documentID)),
                                                maxChars: config.excerptChars)
        let neighbours = taxonomy.children(of: folder.parentCode).filter { $0.holdsUserDocuments && $0.code != folder.code }
            .map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let documents = memories.map { m in
            "- \(m.summaryLine)" + (excerpts[m.documentID].map { "\n  \($0.replacingOccurrences(of: "\n", with: " "))" } ?? "")
        }.joined(separator: "\n")
        let system = try library.render("describe-folder-system", ["folder_language": language,
                                                                   "max_examples": String(config.exampleCount)])
        let user = try library.render("describe-folder-user", [
            "folder": "\(taxonomy.path(of: folder))", "description": folder.description,
            "neighbours": neighbours.isEmpty ? "(none)" : neighbours, "documents": documents,
        ])
        let request = OllamaChatRequest(model: model, messages: [.system(system), .user(user)],
                                        format: ClassificationSchema.folderDescription(maxExamples: config.exampleCount),
                                        options: ["temperature": .number(config.temperature), "num_ctx": .number(Double(numCtx))],
                                        keepAlive: keepAlive, think: nil)
        let response = try await gate.chat(request)
        let answer = try JSONDecoder().decode(FolderDescriptionAnswer.self,
                                              from: Data(AnswerValidator.stripThinking(response.message.content).utf8))
        try await store.setMeta(Self.counterKey(folder.id), "0")
        try await store.setMeta(Self.lastRunKey(folder.id), String(Date().timeIntervalSince1970))
        let title = "Improve description of \(taxonomy.path(of: folder))"
        if try await store.hasPendingProposal(kind: .folderDescription, folderID: folder.id, title: title) { return nil }
        let payload = DescriptionProposal(folderID: folder.id, folderCode: folder.code, oldDescription: folder.description,
                                          newDescription: answer.description, examples: answer.examples,
                                          basedOnDocuments: memories.count)
        let id = try await store.createProposal(kind: .folderDescription, title: title, folderID: folder.id, payload: JSON.string(payload))
        Log.info(.learn, "Proposed description update", ["folder": folder.code, "documents": String(memories.count)])
        return id
    }
}

/// Drafts `_about.md` content for folders the user created by hand, as a proposal.
public struct FolderAbsorber: Sendable {
    public let store: any LearningStore
    public let gate: InferenceGate
    public let library: PromptLibrary
    public let config: LearningConfig
    public let skip: SkipRules

    public init(store: any LearningStore, gate: InferenceGate, library: PromptLibrary, config: LearningConfig, skip: SkipRules) {
        self.store = store
        self.gate = gate
        self.library = library
        self.config = config
        self.skip = skip
    }

    public func propose(folder: TaxonomyFolder, taxonomy: TaxonomySnapshot, model: String, keepAlive: String,
                        numCtx: Int, language: String) async throws {
        let title = "Describe new folder \(taxonomy.path(of: folder))"
        if try await store.hasPendingProposal(kind: .newFolder, folderID: folder.id, title: title) { return }
        let dir = taxonomy.url(for: folder)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { skip.ignoreReason($0) == nil }.prefix(config.absorbSampleFiles).map(\.lastPathComponent)
        let neighbours = taxonomy.children(of: folder.parentCode).filter { $0.holdsUserDocuments && $0.code != folder.code }
            .map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let system = try library.render("absorb-folder-system", ["folder_language": language,
                                                                 "max_examples": String(config.descriptionRefresh.exampleCount)])
        let user = try library.render("absorb-folder-user", [
            "folder": "\(taxonomy.path(of: folder))", "neighbours": neighbours.isEmpty ? "(none)" : neighbours,
            "documents": files.isEmpty ? "(empty folder)" : files.map { "- \($0)" }.joined(separator: "\n"),
        ])
        let request = OllamaChatRequest(model: model, messages: [.system(system), .user(user)],
                                        format: ClassificationSchema.folderDescription(maxExamples: config.descriptionRefresh.exampleCount),
                                        options: ["temperature": .number(config.descriptionRefresh.temperature),
                                                  "num_ctx": .number(Double(numCtx))],
                                        keepAlive: keepAlive, think: nil)
        let response = try await gate.chat(request)
        let answer = try JSONDecoder().decode(FolderDescriptionAnswer.self,
                                              from: Data(AnswerValidator.stripThinking(response.message.content).utf8))
        let payload = NewFolderProposal(folderID: folder.id, folderCode: folder.code, name: folder.name,
                                        description: answer.description, sampledFiles: Array(files))
        try await store.createProposal(kind: .newFolder, title: title, folderID: folder.id, payload: JSON.string(payload))
        Log.info(.learn, "Drafted description for user folder", ["folder": folder.code])
    }
}
