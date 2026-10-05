import ArrumatorCore
import Synchronization

/// What one exchange with the model has sent back to it, which it may give again: words of a search request, as
/// alternatives of a kind's labels or as inside the arrangement's quote, by their search keys, and labels whose quote
/// holds other labels' or kinds of document a person's question never names (`SearchPlanValidator`); and the guesses an
/// answer holds, each subject once, by its field's key: a document's title not made of its words, objects nothing
/// identifies, a date given to a document that writes none, parties without a sender (`AnswerValidator`), or a task's
/// title in another language than its request (`SearchPlanValidator`). Each is noted once a repair sends it
/// (`GuessSentBack.sent`). The model was told, so what it gives again is its answer, not one more mistake to send back
/// until the repairs run out (AGENTS.md §4.5). A refitted prompt starts a fresh exchange, in which the model was told
/// nothing, so it starts with a fresh one.
public final class SentBack: Sendable {
    private let words = Mutex<Set<String>>([])
    private let labels = Mutex<Set<DocumentLabel>>([])
    private let guesses = Mutex<Set<String>>([])

    public init() {}

    func contains(_ words: [String]) -> Bool {
        self.words.withLock { keys in words.allSatisfy { keys.contains(LabelUsage.searchKey($0)) } }
    }

    func insert(_ words: [String]) {
        self.words.withLock { $0.formUnion(words.map(LabelUsage.searchKey)) }
    }

    func contains(_ label: DocumentLabel) -> Bool {
        labels.withLock { $0.contains(label) }
    }

    func insert(_ labels: [DocumentLabel]) {
        self.labels.withLock { $0.formUnion(labels) }
    }

    /// Whether the model was told, in this exchange, of a guess about `subject`, a field by its key.
    func wasTold(_ subject: String) -> Bool {
        guesses.withLock { $0.contains(subject) }
    }

    /// Notes that the model was told of guesses about `subjects`.
    func tell(_ subjects: [String]) {
        guesses.withLock { $0.formUnion(subjects) }
    }
}
