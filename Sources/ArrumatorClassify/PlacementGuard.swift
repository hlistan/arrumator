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

/// Tells whether a level of a decided path is a folder that already exists beside it under another name. Behind a
/// protocol so the guard can be tested without a model.
public protocol FolderJudge: Sendable {
    /// Whether `level`, which the logic calls for inside `place`, is the existing `folder`; nil when it cannot tell.
    func isSame(_ level: FolderLevel, as folder: TaxonomyFolder, inside place: String) async throws -> Bool?
}

/// Embeddings of folder names, cached per model and name.
public actor NameVectors {
    private var cache: [String: [Float]] = [:]

    public init() {}

    public func vectors(for names: [String], embedder: any Embedder) async throws -> [String: [Float]] {
        let missing = Array(Set(names.filter { cache[embedder.modelId + "\u{1}" + $0] == nil }))
        if !missing.isEmpty {
            for (name, vector) in zip(missing, try await embedder.embed(missing)) { cache[embedder.modelId + "\u{1}" + name] = vector }
        }
        return Dictionary(names.compactMap { name in cache[embedder.modelId + "\u{1}" + name].map { (name, $0) } },
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
/// - Any other level is an existing folder of the same name, or of a name so close it would be a duplicate. A name
///   only somewhat close is put to the `FolderJudge`, a few times per document at most, since deciding whether two
///   described folders are the same is a question a model answers far more reliably than matching a whole tree
///   (entity matching; Narayan et al., "Can Foundation Models Wrangle Your Data?", VLDB 2022). Unsure is not the same:
///   a second folder is easier to put right than a document filed with the wrong ones.
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

    /// Names whose embeddings the guard needs: the path's and those of the user's folders.
    public static func names(for ideal: [FolderLevel], taxonomy: TaxonomySnapshot) -> [String] {
        ideal.map(\.name) + taxonomy.folders.filter(\.holdsUserDocuments).map(\.name)
    }

    /// - Parameters:
    ///   - sender: the document's sender as recognised, nil for one the app does not know yet.
    ///   - logic: `LogicStore.version` of the logic the path was decided by.
    ///   - names: embeddings of `names(for:taxonomy:)`; without them, only the same name is the same folder.
    public func place(_ ideal: [FolderLevel], sender: Int64?, documentType: DocumentType, logic: String, yearFolder: Bool,
                      taxonomy: TaxonomySnapshot, names: [String: [Float]], judge: any FolderJudge) async throws -> GuardedPlacement {
        var notes: [String] = []
        var parent: String?
        var similarity: Double?
        var start = 0
        var judged = 0
        // A known sender's documents reach its folder whatever the model does with the levels this time: leaves the
        // sender out, rearranges the ones above it, or adds one below it for documents the folder already holds.
        let senderLevel = ideal.firstIndex { $0.kind == .sender }
        if let sender, let home = home(of: sender, subjects: ideal[..<(senderLevel ?? ideal.count)].filter { $0.kind == .subject },
                                       logic: logic, taxonomy: taxonomy, names: names) {
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
            let resemblance = { (folder: TaxonomyFolder) -> Double? in
                names[level.name].flatMap { vector in names[folder.name].map { Double(VectorCodec.dot(vector, $0)) } }
            }
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
                if let (folder, sim) = closest(inside.filter { $0.kind != .sender }, to: level, resemblance) {
                    if sim >= config.duplicateAbove {
                        notes.append(String(format: "“%@” is the existing “%@” (%.2f)", level.name, folder.name, sim))
                        parent = folder.code
                        similarity = sim
                        continue
                    }
                    if sim >= config.judgeAbove, judged < config.maxJudgements {
                        judged += 1
                        let place = parent.flatMap { taxonomy.folder(code: $0) }.map { taxonomy.path(of: $0) } ?? ""
                        let same = try await judge.isSame(level, as: folder, inside: place)
                        notes.append(String(format: "“%@” and the existing “%@” (%.2f): %@", level.name, folder.name, sim,
                                            same == true ? "the same folder" : same == false ? "different folders" : "unsure, kept apart"))
                        if same == true {
                            parent = folder.code
                            similarity = sim
                            continue
                        }
                    }
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
                      names: [String: [Float]]) -> TaxonomyFolder? {
        let homes = taxonomy.folders.filter { $0.kind == .sender && $0.logic == logic && $0.senders == [sender] }
        guard !subjects.isEmpty else { return homes.count == 1 ? homes.first : nil }
        return homes.filter { home in
            let above = taxonomy.lineage(of: home).dropLast()
            return subjects.allSatisfy { level in
                above.contains { folder in
                    TaxonomyStore.sameName(level.name, folder.name)
                        || (names[level.name].flatMap { v in names[folder.name].map { Double(VectorCodec.dot(v, $0)) } } ?? 0) >= config.duplicateAbove
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
}
