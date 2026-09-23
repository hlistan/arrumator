import ArrumatorCore
import Foundation

public struct CalibrationInput: Sendable, Hashable {
    public var llmConfidence: Double?
    public var chosenCode: String?
    public var isNewFolder: Bool
    /// Similarity between the model's ideal category and the chosen existing folder.
    public var idealSimilarity: Double?
    public var candidates: CandidateSet
    public var ruleHit: FilingRule?
    public var ruleAgrees: Bool
    public var content: ExtractedContentSummary
}

/// The parts of the extracted content the calibrator looks at.
public struct ExtractedContentSummary: Sendable, Hashable {
    public var textOrigin: TextOrigin
    public var ocrConfidence: Double?
    public var dateSource: DateSource
    public var language: String

    public init(_ c: ExtractedContent) {
        textOrigin = c.textOrigin
        ocrConfidence = c.ocr?.meanConfidence
        dateSource = c.entities.documentDate?.source ?? .none
        language = c.language.primary
    }
}

/// Combines model confidence with agreement from past filings and folder similarity, then applies evidence-based
/// modifiers. Decisions that create a new folder rest on the model alone and are scaled down accordingly.
public struct Calibrator: Sendable {
    public let config: CalibrationConfig

    public init(config: CalibrationConfig) { self.config = config }

    /// Maps a cosine similarity linearly from [floor, ceiling] onto [0, 1].
    func mapped(_ cosine: Double) -> Double {
        min(1, max(0, (cosine - config.similarityFloor) / (config.similarityCeiling - config.similarityFloor)))
    }

    public func calibrate(_ input: CalibrationInput, thresholds: Thresholds) -> ConfidenceReport {
        let c = config
        let llm = input.llmConfidence ?? 0
        let knn = input.chosenCode.flatMap { input.candidates.knnShare[$0] }
        let sim = input.chosenCode.flatMap { input.candidates.candidate($0)?.similarity }.map(mapped) ?? 0
        let ideal = input.idealSimilarity.map { min(1, max(0, ($0 - c.idealFloor) / (c.idealCeiling - c.idealFloor))) } ?? 0
        let w = input.candidates.usedMemories ? c.weights : c.weightsNoMemory
        var score = input.isNewFolder ? llm * c.newFolderConfidenceScale
            : w.llm * llm + w.knn * (knn ?? 0) + w.similarity * sim + w.ideal * ideal
        var modifiers: [String: Double] = [:]
        func apply(_ name: String, _ delta: Double) {
            modifiers[name] = delta
            score += delta
        }
        func cap(_ name: String, _ limit: Double) {
            if score > limit {
                modifiers[name] = limit - score
                score = limit
            }
        }
        if let rule = input.ruleHit {
            if input.ruleAgrees {
                let floor = max(score, c.ruleAgreeFloor) + c.ruleAgreeBonus
                modifiers["rule:\(rule.id)"] = floor - score
                score = floor
            } else {
                apply("ruleConflict", c.ruleConflictPenalty)
            }
        }
        if input.isNewFolder { modifiers["newFolderScale"] = c.newFolderConfidenceScale }
        switch input.content.textOrigin {
        case .metadataOnly, .none:
            apply("metadataOnly", c.metadataOnlyPenalty)
            cap("metadataOnlyCap", c.metadataOnlyCap)
        case .vlmOnly:
            cap("vlmOnlyCap", c.vlmOnlyCap)
        default: break
        }
        if let ocr = input.content.ocrConfidence, ocr < c.lowOCRThreshold { apply("lowOCR", c.lowOCRPenalty) }
        if input.content.dateSource == .mtime { apply("dateFromFileTime", c.mtimeDatePenalty) }
        if input.content.language == "other" || input.content.language == "und" { apply("unknownLanguage", c.unknownLanguagePenalty) }
        let final = min(1, max(0, score))
        if input.idealSimilarity != nil { modifiers["idealAgreement"] = ideal }
        return ConfidenceReport(llm: input.llmConfidence, knnAgreement: knn, simAgreement: sim, ruleHit: input.ruleHit?.id,
                                modifiers: modifiers, final: final, band: thresholds.band(for: final), thresholds: thresholds)
    }
}
