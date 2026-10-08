@testable import ArrumatorCore
import Foundation
import Synchronization
import Testing

/// Which labels look alike, kept from one ask to the next (`AlikeLabels`, `LookAlikeMemo`): a change compares only the
/// labels added, one asking while another works a kind out waits for it, and work stopped part way is kept.
@Suite struct LookAlikeTests {
    /// Compares two labels as `LabelSimilarity` does, keeping each pair it is asked about.
    final class Comparisons: Sendable {
        private let pairs = Mutex<[(LabelSimilarity.Key, LabelSimilarity.Key)]>([])

        var asked: [(LabelSimilarity.Key, LabelSimilarity.Key)] { pairs.withLock { $0 } }

        @Sendable func compare(_ a: LabelSimilarity.Key, _ b: LabelSimilarity.Key, atLeast threshold: Double) -> LabelSimilarity.LookAlike? {
            pairs.withLock { $0.append((a, b)) }
            return LabelSimilarity.lookAlike(a, b, atLeast: threshold)
        }

        func forget() { pairs.withLock { $0 = [] } }
    }

    /// The labels of `kind` among `LabelVocabularyTests.manyLabels`.
    static func labels(_ kind: LabelKind) -> [String] { LabelVocabularyTests.manyLabels.filter { $0.0 == kind }.map(\.1) }

    /// Which of `labels` look alike, worked out from nothing.
    static func fromNothing(_ labels: [String], threshold: Double) -> AlikeLabels {
        AlikeLabels(threshold: threshold).updated(to: labels, comparing: LabelSimilarity.lookAlike(_:_:atLeast:)) { false }
    }

    /// Senders of letters alone, so every two are compared: as many as `count`.
    static func senders(_ count: Int) -> [String] {
        let syllables = ["ka", "lo", "mi", "re", "su", "to", "na", "pe", "di", "go", "ba", "ve"]
        return Array(syllables.flatMap { a in syllables.flatMap { b in syllables.map { c in "\(a)\(b)\(c) \(c)\(a) Lda" } } }.prefix(count))
    }

    @Test func aLabelAddedWithTheSameDigitsGroupedOtherwiseIsFoundAtAnyThreshold() {
        let references = ["contract V/2026/532774", "invoice FT 2026/1", "receipt 77"]
        let known = Self.fromNothing(references, threshold: 1)
        #expect(known.pairs.isEmpty, "references written each its own way look alike to none at a threshold of 1")
        let grown = known.updated(to: references + ["contract V2026532774"], comparing: LabelSimilarity.lookAlike(_:_:atLeast:)) { false }
        #expect(grown.pairs == [AlikeLabels.Pair("contract V/2026/532774", "contract V2026532774"):
                                    LabelSimilarity.LookAlike(similarity: 1, reason: .sameDigitsGroupedOtherwise)],
                "a reference added with the same digits as one in use, grouped otherwise, is found with it, whatever the threshold")
        #expect(grown.pairs == Self.fromNothing(references + ["contract V2026532774"], threshold: 1).pairs, "as working them all out finds it")
    }

    @Test func aLabelAddedIsComparedWithTheOthersAloneAndOneGoneWithNone() throws {
        let threshold = try #require(try LabelVocabularyTests.consolidator().config.kinds[.sender]).suggestSimilarity
        let senders = Self.labels(.sender)
        let comparisons = Comparisons()
        let known = AlikeLabels(threshold: threshold).updated(to: senders, comparing: comparisons.compare) { false }
        #expect(known.pairs == Self.fromNothing(senders, threshold: threshold).pairs && !known.pairs.isEmpty, "worked out label by label")
        comparisons.forget()

        let added = "Galp Energia SA"
        let grown = known.updated(to: senders + [added], comparing: comparisons.compare) { false }
        let key = LabelSimilarity.Key(added)
        #expect(comparisons.asked.count == senders.count && comparisons.asked.allSatisfy { $0.0 == key || $0.1 == key },
                "a label added is compared with each label there was, once, and no two of those again")
        #expect(grown.pairs == Self.fromNothing(senders + [added], threshold: threshold).pairs, "and finds what working them all out finds")
        comparisons.forget()

        let fewer = Array(senders.dropFirst(2)) + [added]
        let shrunk = grown.updated(to: fewer, comparing: comparisons.compare) { false }
        #expect(comparisons.asked.isEmpty && shrunk.pairs == Self.fromNothing(fewer, threshold: threshold).pairs,
                "labels no longer in use take their pairs with them, and nothing is compared")
    }

    @Test func aLabelAddedIsComparedOnlyWithTheLabelsOfItsDigits() {
        let objects = Self.labels(.object)
        let comparisons = Comparisons()
        let known = AlikeLabels(threshold: 0.9).updated(to: objects, comparing: comparisons.compare) { false }
        comparisons.forget()
        let grown = known.updated(to: objects + ["contract V2026/532774"], comparing: comparisons.compare) { false }
        #expect(comparisons.asked.count == 3, "labels whose digits differ are never alike, so only those with its digits are compared")
        #expect(grown.pairs == Self.fromNothing(objects + ["contract V2026/532774"], threshold: 0.9).pairs, "and nothing alike is missed")
    }

    @Test func theMemoComparesOnlyWhatChangedSinceAndAppliesKeepApartWhenTheSuggestionsAreRead() async throws {
        let memo = LookAlikeMemo()
        let comparisons = Comparisons()
        func suggestions(_ c: LabelConsolidator) async throws -> [LabelSuggestion] {
            try await c.suggestions(by: memo, comparing: comparisons.compare)
        }
        func consolidator(rules: [LabelRule] = [], _ vocabulary: [(LabelKind, String, Int)]) throws -> LabelConsolidator {
            try LabelVocabularyTests.consolidator(rules: rules, vocabulary: vocabulary)
        }
        let vocabulary: [(LabelKind, String, Int)] = [(.party, "Maria Silva", 3), (.party, "Mario Silva", 1), (.topic, "electricity", 2)]
        let first = try await suggestions(try consolidator(vocabulary))
        #expect(comparisons.asked.count == 1 && first.map(\.into) == ["Maria Silva"], "the first time, each pair of a kind is compared")
        comparisons.forget()
        let filed = try await suggestions(try consolidator([(.party, "Mario Silva", 4), (.party, "Maria Silva", 3), (.topic, "electricity", 2)]))
        #expect(comparisons.asked.isEmpty && filed.map(\.into) == ["Mario Silva"],
                "documents filed with labels in use compare nothing: only which label more documents have changes")
        let apart = try await suggestions(try consolidator(rules: [LabelVocabularyTests.rule(1, .party, "Maria Silva", .keepApart, "Mario Silva")],
                                                           vocabulary))
        #expect(comparisons.asked.isEmpty && apart.isEmpty, "a pair the user keeps apart is left out as the suggestions are read")
        _ = try await suggestions(try consolidator(vocabulary + [(.topic, "electricty", 1)]))
        #expect(comparisons.asked.count == 1, "a new label is compared with the labels of its kind alone")
        comparisons.forget()
        var looser = try consolidator(vocabulary).config
        looser.kinds[.party]?.suggestSimilarity = 0.5
        _ = try await suggestions(LabelConsolidator(config: looser, rules: [],
                                                    vocabulary: LabelVocabularyTests.vocabulary(vocabulary + [(.party, "Ana Costa", 1)])))
        #expect(comparisons.asked.count == 3, "another threshold compares every pair of the kind again")
    }

    @Test func twoAskingAtOnceWorkAKindOutOnce() async throws {
        let senders = Self.senders(300)
        let memo = LookAlikeMemo()
        let comparisons = Comparisons()
        async let one = memo.alike(.sender, labels: senders, threshold: 0.85, comparing: comparisons.compare)
        async let other = memo.alike(.sender, labels: senders, threshold: 0.85, comparing: comparisons.compare)
        let (first, second) = try await (one, other)
        #expect(comparisons.asked.count == senders.count * (senders.count - 1) / 2,
                "every pair is compared once: the second waits for the first, and has nothing left to compare")
        #expect(first.pairs == second.pairs && first.pairs == Self.fromNothing(senders, threshold: 0.85).pairs, "and both have it all")
    }

    @Test func aWorkingOutStoppedPartWayStopsAndTheNextGoesOnFromWhereItStopped() async throws {
        let senders = Self.senders(60)
        let memo = LookAlikeMemo()
        let comparisons = Comparisons()
        // Stopped by the app as a new change comes, here once it has compared some pairs.
        let stopping: AlikeLabels.Comparing = { a, b, threshold in
            if comparisons.asked.count == 100 { withUnsafeCurrentTask { $0?.cancel() } }
            return comparisons.compare(a, b, atLeast: threshold)
        }
        let stopped = Task { try await memo.alike(.sender, labels: senders, threshold: 0.85, comparing: stopping) }
        await #expect(throws: CancellationError.self, "stopped, it stops") { try await stopped.value }
        let all = senders.count * (senders.count - 1) / 2
        let before = comparisons.asked.count
        #expect(before < all, "before it has compared every pair")
        let rest = try await memo.alike(.sender, labels: senders, threshold: 0.85, comparing: comparisons.compare)
        #expect(comparisons.asked.count == all, "the next compares only what was left, so no pair is compared twice")
        #expect(rest.pairs == Self.fromNothing(senders, threshold: 0.85).pairs, "and has it all")
    }
}
