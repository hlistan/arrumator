import Foundation
import Synchronization

/// Which labels of a kind look alike: every pair of them at least `threshold` alike, or with the same digits grouped
/// otherwise, whatever the threshold (`LabelSimilarity.lookAlike`), with why and how alike.
/// It is worked out label by label, each compared with the labels before it, so what was worked out for some labels is
/// brought up to date for others by comparing only the labels added with the rest, and dropping the pairs of the labels
/// gone (`updated(to:comparing:stoppingWhen:)`): a document filed with a new sender costs as many comparisons as there
/// are senders, not as many as there are pairs of them.
struct AlikeLabels: Sendable {
    /// Two labels, the first in sorted order first, as a pair is compared.
    struct Pair: Sendable, Hashable {
        let first: String
        let second: String

        init(_ a: String, _ b: String) {
            (first, second) = a < b ? (a, b) : (b, a)
        }
    }

    /// How two labels are compared: `LabelSimilarity.lookAlike(_:_:atLeast:)`, or a test's double of it.
    typealias Comparing = @Sendable (LabelSimilarity.Key, LabelSimilarity.Key, Double) -> LabelSimilarity.LookAlike?

    let threshold: Double
    /// Each pair that looks alike, why, and how alike.
    private(set) var pairs: [Pair: LabelSimilarity.LookAlike] = [:]
    private var keys: [String: LabelSimilarity.Key] = [:]
    /// The labels by their digits: only labels with the same digits in the same order can look alike, unless the
    /// threshold is 0 or less, which any two labels reach.
    private var byDigits: [String: [String]] = [:]

    init(threshold: Double) {
        self.threshold = threshold
    }

    /// These, for `labels`: the pairs of the labels no longer among them dropped, and each label new among them compared,
    /// by `comparing`, with every label that could look alike to it, once. Before each label it compares, it asks
    /// `stopping` whether to go on: stopped, what it gives holds the labels it has compared, each pair among them, and
    /// the next update compares the rest, so work cut short is never lost.
    func updated(to labels: [String], comparing: Comparing, stoppingWhen stopping: () -> Bool) -> AlikeLabels {
        let wanted = Set(labels)
        var next = self
        let gone = Set(keys.keys).subtracting(wanted)
        if !gone.isEmpty {
            next.pairs = pairs.filter { !gone.contains($0.key.first) && !gone.contains($0.key.second) }
            for label in gone {
                guard let key = next.keys.removeValue(forKey: label) else { continue }
                next.byDigits[key.digits]?.removeAll { $0 == label }
            }
        }
        for label in wanted.subtracting(keys.keys).sorted() {
            if stopping() { break }
            let key = LabelSimilarity.Key(label)
            let others = threshold > 0 ? next.byDigits[key.digits, default: []] : Array(next.keys.keys)
            for other in others {
                guard let otherKey = next.keys[other] else { continue }
                let pair = Pair(label, other)
                let (first, second) = pair.first == label ? (key, otherKey) : (otherKey, key)
                if let alike = comparing(first, second, threshold) { next.pairs[pair] = alike }
            }
            next.keys[label] = key
            next.byDigits[key.digits, default: []].append(label)
        }
        return next
    }
}

/// Which labels look alike, for each kind, as it was last worked out (`AlikeLabels`), so that asking again, as the app
/// does to count the suggestions at every change it hears of, such as each document filed, compares only the labels
/// added since, and nothing when there are none: how many documents have each label, which orders the suggestions, and
/// the pairs the user kept apart, which leave some out, are applied when they are read. A kind is worked out from
/// nothing the first time and when its threshold changes; the runtime does it once the archive is open, so the app
/// seldom waits for it (`LabelStore.workOutLookAlikes`). `PipelineServices` keeps one, which every `LabelStore` it makes
/// shares.
public final class LookAlikeMemo: Sendable {
    private let memo = Mutex<[LabelKind: AlikeLabels]>([:])
    /// One update at a time: a caller that comes while another works a kind out waits for it, and then compares only
    /// what is left, never working the kind out from nothing beside it. A caller stopped while it waits stops at once.
    private let turn = AsyncSemaphore(permits: 1)
    /// How many suggestions there were when they were last worked out, and the subscribers told of each new count.
    private let counted = Mutex<(last: Int?, followers: [UUID: AsyncStream<Int>.Continuation])>((nil, [:]))

    public init() {}

    /// How many pairs of labels look alike and wait for the user, each time that changes as they are worked out
    /// (`LabelStore.suggestions()`), the last known first: what the app counts without waiting for them to be worked
    /// out. A stream per subscriber, which ends when its consumer is cancelled.
    public func suggestionCounts() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.counted.withLock { _ = $0.followers.removeValue(forKey: id) } }
        counted.withLock { state in
            state.followers[id] = continuation
            if let last = state.last { continuation.yield(last) }
        }
        return stream
    }

    /// Tells every subscriber how many suggestions there are now, when that changed; told under the lock, so that no
    /// subscriber is left with an older count than the last.
    func publish(suggestions count: Int) {
        counted.withLock { state in
            guard state.last != count else { return }
            state.last = count
            for follower in state.followers.values { follower.yield(count) }
        }
    }

    /// What is known of `kind`, as it was last worked out, or as far as a stopped working out came.
    func known(_ kind: LabelKind) -> AlikeLabels? {
        memo.withLock { $0[kind] }
    }

    /// Which of `labels` of `kind` look alike at `threshold`, brought up to date from what was known of the kind. Stopped
    /// part way, it keeps the labels it compared, for the next to go on from, and throws `CancellationError`.
    func alike(_ kind: LabelKind, labels: [String], threshold: Double, comparing: @escaping AlikeLabels.Comparing) async throws -> AlikeLabels {
        try await turn.withPermit {
            let last = self.known(kind).flatMap { $0.threshold == threshold ? $0 : nil }
            let alike = (last ?? AlikeLabels(threshold: threshold)).updated(to: labels, comparing: comparing) { Task.isCancelled }
            self.memo.withLock { $0[kind] = alike }
            try Task.checkCancellation()
            return alike
        }
    }
}
