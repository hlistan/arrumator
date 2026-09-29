import ArrumatorCore
import Foundation
import NaturalLanguage

/// Language identification constrained to the configured document languages.
///
/// The primary language is `other` when the best hypothesis is below `languageMinConfidence`, and `und` when
/// the text has no letters. A fresh `NLLanguageRecognizer` is created per call, so the detector is freely
/// shareable across tasks.
public struct LanguageDetector: Sendable {
    private let languages: [String]
    private let sampleChars: Int
    private let minConfidence: Double

    public init(config: ExtractionConfig) {
        languages = config.languages
        sampleChars = config.languageSampleChars
        minConfidence = config.languageMinConfidence
    }

    public func detect(_ text: String) -> LanguageGuess {
        let hypotheses = self.hypotheses(text)
        guard let best = hypotheses.max(by: { $0.value < $1.value }) else { return .undetermined }
        return LanguageGuess(primary: best.value >= minConfidence ? best.key : Self.other,
                             confidence: best.value, hypotheses: hypotheses)
    }

    /// Configured languages, most likely first; configuration order breaks ties and applies when undetermined.
    public func ranked(for text: String) -> [String] {
        let hypotheses = self.hypotheses(text)
        return languages.enumerated()
            .sorted { lhs, rhs in
                let l = hypotheses[lhs.element] ?? 0
                let r = hypotheses[rhs.element] ?? 0
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func hypotheses(_ text: String) -> [String: Double] {
        let sample = String(text.prefix(sampleChars))
        guard !languages.isEmpty, sample.contains(where: \.isLetter) else { return [:] }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map { NLLanguage(rawValue: $0) }
        recognizer.processString(sample)
        // The recognizer may still list related languages (uk, bg, ca) at zero probability; keep configured ones.
        let raw = recognizer.languageHypotheses(withMaximum: languages.count)
        return Dictionary(raw.map { ($0.key.rawValue, $0.value) }.filter { languages.contains($0.0) },
                          uniquingKeysWith: max)
    }

    /// Code used when the text is in a language outside the configured set (or too ambiguous to tell).
    static let other = "other"
}
