import ArrumatorCore
import Foundation

public struct GuardedPlacement: Sendable, Codable, Hashable {
    public var folderCode: String?
    public var newFolder: FolderSpec?
    /// Name similarity between the model's ideal category and the final existing folder (nil for a new folder).
    public var idealSimilarity: Double?
    public var notes: [String]
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

/// Checks the model's mapping from the ideal home it described onto the actual tree. Names that carry different
/// qualifiers in parentheses ("Taxes (Portugal)" vs "Taxes (Russia)") are different categories by the organising
/// principles, however similar they look. Otherwise: an existing folder whose name does not resemble the ideal
/// category, or that sits in an area unlike the ideal area, is replaced by the ideal (new) folder — so logic can
/// move a topic to another part of the archive; a new folder that nearly duplicates an existing one in the ideal
/// area reuses it; a new area that nearly duplicates an existing area joins it.
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

    /// Names whose embeddings the guard needs.
    public static func names(for decision: ValidatedDecision, taxonomy: TaxonomySnapshot) -> [String] {
        [decision.ideal.name] + [decision.ideal.newAreaName].compactMap { $0 }
            + taxonomy.fileableCategories.map(\.name) + taxonomy.areas.filter { $0.origin != .system }.map(\.name)
    }

    public func review(_ decision: ValidatedDecision, taxonomy: TaxonomySnapshot, names: [String: [Float]]) -> GuardedPlacement {
        var result = GuardedPlacement(folderCode: decision.folderCode, newFolder: decision.newFolder, idealSimilarity: nil, notes: [])
        guard let ideal = names[decision.ideal.name] else { return result }
        func similarity(_ name: String) -> Double? { names[name].map { Double(VectorCodec.dot(ideal, $0)) } }
        /// How similar a category's area is to the ideal area, when both can be compared.
        func areaSimilarity(_ folder: TaxonomyFolder) -> Double? {
            guard decision.ideal.areaCode == nil, let idealArea = decision.ideal.newAreaName.flatMap({ names[$0] }),
                  let area = folder.parentCode.flatMap({ taxonomy.folder(code: $0) }), let vector = names[area.name] else { return nil }
            return Double(VectorCodec.dot(idealArea, vector))
        }
        func inIdealArea(_ folder: TaxonomyFolder) -> Bool {
            if let code = decision.ideal.areaCode { return folder.parentCode == code }
            return (areaSimilarity(folder) ?? 1) >= config.areaMismatchBelow
        }
        if let code = decision.folderCode, let folder = taxonomy.folder(code: code) {
            let sim = similarity(folder.name)
            result.idealSimilarity = sim
            if Self.qualifiersDiffer(decision.ideal.name, folder.name) {
                result.notes.append("“\(folder.name)” and the ideal “\(decision.ideal.name)” differ in scope")
                result.folderCode = nil
                result.newFolder = decision.ideal
            } else if let sim, sim < config.mismatchBelow {
                result.notes.append(String(format: "“%@” is not the ideal “%@” (%.2f)", folder.name, decision.ideal.name, sim))
                result.folderCode = nil
                result.newFolder = decision.ideal
            } else if !inIdealArea(folder) {
                result.notes.append(String(format: "“%@” is in another part of the archive than the ideal area “%@” (%.2f)",
                                           folder.name, decision.ideal.newAreaName ?? "", areaSimilarity(folder) ?? 0))
                result.folderCode = nil
                result.newFolder = decision.ideal
            } else {
                return result
            }
        }
        // The ideal (or proposed) folder may already exist under another code in the ideal area: reuse it rather than
        // duplicate it.
        if let best = taxonomy.fileableCategories.filter({ !Self.qualifiersDiffer(decision.ideal.name, $0.name) && inIdealArea($0) })
            .compactMap({ f in similarity(f.name).map { (f, $0) } }).max(by: { $0.1 < $1.1 }), best.1 >= config.duplicateAbove {
            result.notes.append(String(format: "“%@” already exists as %@ %@ (%.2f); reusing it", decision.ideal.name, best.0.code,
                                       best.0.name, best.1))
            result.folderCode = best.0.code
            result.newFolder = nil
            result.idealSimilarity = best.1
            return result
        }
        if var spec = result.newFolder, spec.areaCode == nil, let areaName = spec.newAreaName, let areaVector = names[areaName],
           let best = taxonomy.areas.filter({ $0.origin != .system })
               .compactMap({ a in names[a.name].map { (a, Double(VectorCodec.dot(areaVector, $0))) } }).max(by: { $0.1 < $1.1 }),
           best.1 >= config.areaMatchAbove {
            result.notes.append(String(format: "new area “%@” is existing %@ %@ (%.2f)", areaName, best.0.code, best.0.name, best.1))
            spec.areaCode = best.0.code
            spec.newAreaName = nil
            spec.newAreaDescription = nil
            result.newFolder = spec
        }
        return result
    }
}
