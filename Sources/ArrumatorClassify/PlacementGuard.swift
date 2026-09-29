import ArrumatorCore
import Foundation

public struct GuardedPlacement: Sendable, Codable, Hashable {
    /// The existing folder the whole path leads to; nil when part of it has to be created.
    public var folderCode: String?
    public var newFolder: FolderSpec?
    /// How similar the last level of the path is to the existing folder it became (nil for a new folder).
    public var idealSimilarity: Double?
    public var notes: [String]
    /// Why the document must wait for the user instead: the path would put it with another sender's documents.
    public var conflict: String?
}

/// Which of the folders beside a level of a decided path the level is, when it may already exist under another name.
public enum FolderChoice: Sendable, Hashable {
    /// The level is this folder.
    case folder(TaxonomyFolder)
    /// The level is none of them: a folder of its own.
    case none
    /// It cannot be told, which the guard treats as none of them.
    case unsure
}

/// Tells which folder beside it, if any, a level of a decided path is. Behind a protocol so the guard can be tested
/// without a model.
public protocol FolderJudge: Sendable {
    /// Which of `candidates`, the folders inside `place` that `level` may be, the most alike first, it is.
    func choose(_ level: FolderLevel, among candidates: [TaxonomyFolder], inside place: String) async throws -> FolderChoice
}

/// Embeddings of short texts (folder names, and names with descriptions), cached per model and text.
public actor TextVectors {
    private var cache: [String: [Float]] = [:]

    public init() {}

    public func vectors(for texts: [String], embedder: any Embedder) async throws -> [String: [Float]] {
        let missing = Array(Set(texts.filter { cache[embedder.modelId + "\u{1}" + $0] == nil }))
        if !missing.isEmpty {
            for (text, vector) in zip(missing, try await embedder.embed(missing)) { cache[embedder.modelId + "\u{1}" + text] = vector }
        }
        return Dictionary(texts.compactMap { text in cache[embedder.modelId + "\u{1}" + text].map { (text, $0) } },
                          uniquingKeysWith: { a, _ in a })
    }
}

/// Places the path the model decided by the logic onto the actual tree, from the top down, so that nothing is filed
/// where it does not belong while the tree keeps the shape the logic gives it.
///
/// - A level that stands for the document's sender is that sender's folder, recognised by the documents in it (their
///   sender was recognised by what identifies it: a tax number, an IBAN, a domain), never by the folder's name. A known
///   sender's documents go where its documents are under the current logic, however the model words or arranges the
///   path this time, but only under the subject the document is about: a bank serving a company and a person has a
///   folder under each. A folder holding another sender's documents is never reused, and one of the same name there
///   sends the document to review. Inside a sender's folder, a level joins the folder holding that sender's documents
///   of the same type before a sibling is made for it.
/// - Any other level is an existing folder of the same name, or of a name so close it would be a duplicate. Otherwise
///   it is canonicalized: the model named and described it freely, from the logic and the document alone, and the
///   folders beside it that it may be are offered to the `FolderJudge` at once, the most alike first, to pick the one
///   it is or none (CESI, Vashishth et al., WWW 2018; Extract-Define-Canonicalize, Zhang & Soh, EMNLP 2024). Picking
///   among described folders is a question a model answers far more reliably than matching a whole tree (entity
///   matching; Narayan et al., "Can Foundation Models Wrangle Your Data?", VLDB 2022), and it is asked a few times per
///   document at most. Unsure is none of them: a second folder is easier to put right than a document filed with the
///   wrong ones.
/// - Names with different qualifiers in parentheses ("… (Portugal)", "… (Russia)") are never the same folder.
public struct PlacementGuard: Sendable {
    public let config: ClassificationConfig.PlacementGuard

    public init(config: ClassificationConfig.PlacementGuard) { self.config = config }

    /// Trailing parenthesised qualifier, normalised: "Taxes (Portugal)" → "portugal".
    static func qualifier(_ name: String) -> String? {
        guard let m = name.firstMatch(of: /\(([^()]+)\)\s*$/) else { return nil }
        return String(m.1).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    static func qualifiersDiffer(_ a: String, _ b: String) -> Bool {
        guard let qa = qualifier(a), let qb = qualifier(b) else { return false }
        return qa != qb
    }

    /// Separates a folder's name from its description in the text embedded for both.
    static let describedSeparator = ": "

    /// The text embedded for a folder or a level of a path, its name with what it holds.
    public static func described(_ name: String, _ description: String) -> String {
        description.isEmpty ? name : name + describedSeparator + description
    }

    /// Names whose embeddings the guard needs: the path's and those of the user's folders.
    public static func names(for ideal: [FolderLevel], taxonomy: TaxonomySnapshot) -> [String] {
        ideal.map(\.name) + taxonomy.folders.filter(\.holdsUserDocuments).map(\.name)
    }

    /// The user's folders with their descriptions, as embedded: they change only when a folder is described again.
    public static func described(_ taxonomy: TaxonomySnapshot) -> [String] {
        taxonomy.folders.filter(\.holdsUserDocuments).map { described($0.name, $0.description) }
    }

    /// The levels of a path with their descriptions, as embedded: new with every document.
    public static func described(_ ideal: [FolderLevel]) -> [String] {
        ideal.map { described($0.name, $0.description) }
    }

    /// - Parameters:
    ///   - sender: the document's sender as recognised, nil for one the app does not know yet.
    ///   - logic: `LogicStore.version` of the logic the path was decided by.
    ///   - vectors: embeddings of `names(for:taxonomy:)` and of `described(_:)` for the path and the tree, keyed by
    ///     the text embedded; without them, only the same name is the same folder.
    public func place(_ ideal: [FolderLevel], sender: Int64?, documentType: DocumentType, logic: String, yearFolder: Bool,
                      taxonomy: TaxonomySnapshot, vectors: [String: [Float]], judge: any FolderJudge) async throws -> GuardedPlacement {
        var notes: [String] = []
        var parent: String?
        var similarity: Double?
        var start = 0
        var judged = 0
        // A known sender's documents reach its folder whatever the model does with the levels this time: leaves the
        // sender out, rearranges the ones above it, or adds one below it for documents the folder already holds.
        let senderLevel = ideal.firstIndex { $0.kind == .sender }
        if let sender, let home = home(of: sender, subjects: ideal[..<(senderLevel ?? ideal.count)].filter { $0.kind == .subject },
                                       logic: logic, taxonomy: taxonomy, vectors: vectors) {
            notes.append("the sender's documents are in \(taxonomy.path(of: home))")
            parent = home.code
            similarity = 1
            start = home.documentTypes.contains(documentType) ? ideal.count : senderLevel.map { $0 + 1 } ?? ideal.count
        }
        for index in ideal.indices where index >= start {
            let level = ideal[index]
            let all = taxonomy.children(of: parent)
            if let system = all.first(where: { !$0.holdsUserDocuments && TaxonomyStore.sameName($0.name, level.name) }) {
                notes.append("“\(level.name)” is the app's own \(taxonomy.path(of: system)); nothing is filed there")
                return GuardedPlacement(folderCode: nil, newFolder: nil, idealSimilarity: nil, notes: notes, conflict: nil)
            }
            let inside = all.filter(\.holdsUserDocuments)
            let resemblance = { (folder: TaxonomyFolder) -> Double? in Self.cosine(vectors[level.name], vectors[folder.name]) }
            // Only a folder holding no documents but this sender's can take this document as a sender's folder;
            // whatever the model calls the level, another sender's folder of the same name is never it.
            let fits = { (folder: TaxonomyFolder) in sender.map { folder.senders.isSubset(of: [$0]) } ?? folder.senders.isEmpty }
            if let same = inside.first(where: { TaxonomyStore.sameName($0.name, level.name) }),
               level.kind == .sender || same.kind == .sender, !fits(same) {
                let conflict = "“\(taxonomy.path(of: same))” holds another sender's documents"
                return GuardedPlacement(folderCode: nil, newFolder: nil, idealSimilarity: nil, notes: notes + [conflict], conflict: conflict)
            }
            if level.kind == .sender {
                if let sender, let own = inside.first(where: { $0.kind == .sender && $0.senders == [sender] }) {
                    notes.append("“\(level.name)” is the sender's own “\(own.name)”")
                    parent = own.code
                    similarity = 1
                    continue
                }
                if let same = inside.first(where: { TaxonomyStore.sameName($0.name, level.name) }) {
                    parent = same.code
                    similarity = 1
                    continue
                }
                if let (folder, sim) = closest(inside.filter(fits), to: level, resemblance), sim >= config.duplicateAbove {
                    notes.append(String(format: "“%@” is the existing “%@” (%.2f)", level.name, folder.name, sim))
                    parent = folder.code
                    similarity = sim
                    continue
                }
            } else {
                if let same = inside.first(where: { TaxonomyStore.sameName($0.name, level.name) }) {
                    parent = same.code
                    similarity = 1
                    continue
                }
                if let above = parent.flatMap({ taxonomy.folder(code: $0) }), above.kind == .sender,
                   let alike = inside.first(where: { $0.kind != .sender && $0.documentTypes.contains(documentType) }) {
                    notes.append("“\(level.name)” is “\(alike.name)”, where the sender's \(documentType.rawValue) documents are")
                    parent = alike.code
                    similarity = 1
                    continue
                }
                let topics = inside.filter { $0.kind != .sender }
                if let (folder, sim) = closest(topics, to: level, resemblance), sim >= config.duplicateAbove {
                    notes.append(String(format: "“%@” is the existing “%@” (%.2f)", level.name, folder.name, sim))
                    parent = folder.code
                    similarity = sim
                    continue
                }
                let offered = Array(offers(topics, to: level, vectors: vectors).prefix(config.choices))
                if !offered.isEmpty, judged < config.maxJudgements {
                    judged += 1
                    let place = parent.flatMap { taxonomy.folder(code: $0) }.map { taxonomy.path(of: $0) } ?? ""
                    let choice = try await judge.choose(level, among: offered.map(\.folder), inside: place)
                    let listed = offered.map { String(format: "“%@” (%.2f)", $0.folder.name, $0.similarity) }.joined(separator: ", ")
                    if case let .folder(chosen) = choice, let pick = offered.first(where: { $0.folder.code == chosen.code }) {
                        notes.append("“\(level.name)” is the existing “\(pick.folder.name)”, chosen among \(listed)")
                        parent = pick.folder.code
                        similarity = pick.similarity
                        continue
                    }
                    notes.append("“\(level.name)” is " + (choice == .unsure ? "perhaps one of \(listed): unsure, kept apart" : "none of \(listed)"))
                }
            }
            let rest = Array(ideal[index...])
            notes.append("new: \(rest.map(\.name).joined(separator: TaxonomySnapshot.pathSeparator))"
                         + (parent.flatMap { taxonomy.folder(code: $0) }.map { " inside \(taxonomy.path(of: $0))" } ?? ""))
            return GuardedPlacement(folderCode: nil,
                                    newFolder: FolderSpec(parentCode: parent, levels: rest, yearSubfolders: yearFolder,
                                                          yearRule: yearFolder ? .documentDate : nil, logic: logic),
                                    idealSimilarity: nil, notes: notes, conflict: nil)
        }
        return GuardedPlacement(folderCode: parent, newFolder: nil, idealSimilarity: similarity, notes: notes, conflict: nil)
    }

    /// The folder of `sender` that the current logic made, under the subjects the path names. When the path names no
    /// subject, the sender's only folder; with folders under several subjects, none, rather than a guess.
    private func home(of sender: Int64, subjects: ArraySlice<FolderLevel>, logic: String, taxonomy: TaxonomySnapshot,
                      vectors: [String: [Float]]) -> TaxonomyFolder? {
        let homes = taxonomy.folders.filter { $0.kind == .sender && $0.logic == logic && $0.senders == [sender] }
        guard !subjects.isEmpty else { return homes.count == 1 ? homes.first : nil }
        return homes.filter { home in
            let above = taxonomy.lineage(of: home).dropLast()
            return subjects.allSatisfy { level in
                above.contains { folder in
                    TaxonomyStore.sameName(level.name, folder.name)
                        || (Self.cosine(vectors[level.name], vectors[folder.name]) ?? 0) >= config.duplicateAbove
                }
            }
        }.max { $0.documentCount < $1.documentCount }
    }

    /// The folder among `candidates` whose name is closest to the level's, when names can be compared; one whose
    /// qualifier differs never counts.
    private func closest(_ candidates: [TaxonomyFolder], to level: FolderLevel,
                         _ resemblance: (TaxonomyFolder) -> Double?) -> (TaxonomyFolder, Double)? {
        candidates.filter { !Self.qualifiersDiffer(level.name, $0.name) }
            .compactMap { folder in resemblance(folder).map { (folder, $0) } }
            .max { $0.1 < $1.1 }
    }

    /// The folders among `candidates` that the level may be, the most alike first: those whose name, or name with
    /// description, is at least `offerAbove` like the level's, ranked by reciprocal rank fusion of the two rankings
    /// (Cormack, Clarke & Büttcher, SIGIR 2009). Each ranking finds what the other misses: names keep "Finanças" beside
    /// "Finance" across languages when the descriptions differ, descriptions keep "Household Expenses" beside
    /// "Utilities" when the names differ (measured in docs/organizing-principles-sources.md). One whose qualifier
    /// differs is never offered.
    func offers(_ candidates: [TaxonomyFolder], to level: FolderLevel,
                vectors: [String: [Float]]) -> [(folder: TaxonomyFolder, similarity: Double)] {
        let eligible = candidates.filter { !Self.qualifiersDiffer(level.name, $0.name) }
        let text = Self.described(level.name, level.description)
        let byName = eligible.compactMap { f in Self.cosine(vectors[level.name], vectors[f.name]).map { (f.code, $0) } }
        let byText = eligible.compactMap { f in Self.cosine(vectors[text], vectors[Self.described(f.name, f.description)]).map { (f.code, $0) } }
        func ranks(_ scored: [(String, Double)]) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.enumerated()
                .map { ($0.element.0, $0.offset + 1) })
        }
        let rankings = [ranks(byName), ranks(byText)]
        let best = Dictionary((byName + byText).map { ($0.0, $0.1) }, uniquingKeysWith: max)
        return eligible.compactMap { folder -> (folder: TaxonomyFolder, similarity: Double, fused: Double)? in
            guard let similarity = best[folder.code], similarity >= config.offerAbove else { return nil }
            let fused = rankings.compactMap { $0[folder.code] }.reduce(0) { $0 + 1 / (config.rankFusionK + Double($1)) }
            return (folder, similarity, fused)
        }
        .sorted { a, b in a.fused != b.fused ? a.fused > b.fused : a.similarity != b.similarity ? a.similarity > b.similarity : a.folder.code < b.folder.code }
        .map { ($0.folder, $0.similarity) }
    }

    static func cosine(_ a: [Float]?, _ b: [Float]?) -> Double? {
        guard let a, let b else { return nil }
        return Double(VectorCodec.dot(a, b))
    }
}
