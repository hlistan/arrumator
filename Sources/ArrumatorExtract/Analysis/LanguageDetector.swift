import ArrumatorCore
import Foundation
import NaturalLanguage

/// Language identification over every language NaturalLanguage knows: a document may be in any of them.
///
/// The primary language is `other` when the best hypothesis is below `languageMinConfidence`, and `und` when
/// the text has no letters. A fresh `NLLanguageRecognizer` is created per call, so the detector is freely
/// shareable across tasks.
public struct LanguageDetector: Sendable {
    private let ocrLanguages: [String]
    private let sampleChars: Int
    private let minConfidence: Double

    /// Hypotheses kept with a guess, for the trace; the best decides.
    static let hypothesesKept = 3

    public init(config: ExtractionConfig) {
        ocrLanguages = config.ocrLanguages
        sampleChars = config.languageSampleChars
        minConfidence = config.languageMinConfidence
    }

    public func detect(_ text: String) -> LanguageGuess {
        let hypotheses = self.hypotheses(text)
        guard let best = hypotheses.max(by: { $0.value < $1.value }) else { return .undetermined }
        return LanguageGuess(primary: best.value >= minConfidence ? best.key : Self.other,
                             confidence: best.value, hypotheses: hypotheses)
    }

    /// The languages text recognition is told to expect: the text's own language first when it is sure of one, then
    /// the configured hints, most likely first, their order breaking ties.
    public func ranked(for text: String) -> [String] {
        let guess = detect(text)
        let hints = ocrLanguages.enumerated()
            .sorted { lhs, rhs in
                let l = guess.hypotheses[lhs.element] ?? 0
                let r = guess.hypotheses[rhs.element] ?? 0
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .map(\.element)
        let own = guess.primary.count == DocumentLabel.languageCodeLength && !hints.contains(guess.primary) ? [guess.primary] : []
        return own + hints
    }

    private func hypotheses(_ text: String) -> [String: Double] {
        let sample = String(text.prefix(sampleChars))
        guard sample.contains(where: \.isLetter) else { return [:] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        // A script variant (`zh-Hans`, `zh-Hant`) is its language, by its ISO 639-1 code like every other.
        return Dictionary(recognizer.languageHypotheses(withMaximum: Self.hypothesesKept).map { hypothesis in
            (Locale.Language(identifier: hypothesis.key.rawValue).languageCode?.identifier(.alpha2) ?? hypothesis.key.rawValue, hypothesis.value)
        }, uniquingKeysWith: +)
    }

    /// Code used when the text's language is too ambiguous to tell.
    static let other = "other"
}
