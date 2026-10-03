import ArrumatorCore
import Foundation

/// How much of a prompt a model's context holds: the context (`num_ctx`, in tokens) less what is kept for the answer
/// (`num_predict`), at an estimated `ollama.charsPerToken` characters a token, an estimate that fits text in Latin script
/// and may not others. A prompt longer than its context is not read whole by the model, so a search task's request and a
/// question are cut to fit before they are sent, leaving out what they are shown, and say so in their trace, which also
/// keeps how many tokens Ollama counted each prompt took and says when the context was full, as when the estimate was
/// wrong (`full`). A document's reading is not: its prompt is bounded by `analysis.excerptChars`.
struct PromptBudget {
    let numCtx: Int
    let numPredict: Int
    let charsPerToken: Double

    /// The characters a prompt may hold.
    var room: Int { max(0, Int((Double(numCtx - numPredict) * charsPerToken).rounded(.down))) }

    /// Whether `parts`, sent together, fit the room.
    func fits(_ parts: String...) -> Bool { parts.reduce(0) { $0 + $1.count } <= room }

    /// The tokens each call's prompt took, as Ollama counted them (`prompt_eval_count`), for the calls it said so of.
    static func promptTokens(_ calls: [ModelCall]) -> [Int] { calls.compactMap { $0.metrics?.promptTokens } }

    /// What the trace says when a call's prompt took all the context holds beside the answer, by Ollama's own count: the
    /// estimate of `ollama.charsPerToken` fell short for this text, and the model may not have read the prompt whole.
    /// Nil when every prompt fit.
    func full(_ calls: [ModelCall]) -> String? {
        let limit = numCtx - numPredict
        guard let most = Self.promptTokens(calls).max(), most >= limit else { return nil }
        return "the model's context was full: a prompt took \(most) tokens of the \(limit) beside the answer (ollama.charsPerToken)"
    }
}

/// What was left out of what an answer was shown, so its prompt fits the model's context (`PromptBudget`): documents
/// shown by name instead of with their text, earlier exchanges not shown, and documents not listed at all.
struct ContextTrim: Codable, Hashable {
    var textsLeftOut = 0
    var exchangesLeftOut = 0
    var namesLeftOut = 0

    var isEmpty: Bool { self == ContextTrim() }

    /// `context` with one thing less to show, the least the answer needs first: the earliest exchange but the latest;
    /// then the text of the last document shown with it, which is then listed by name; then the latest exchange, which a
    /// question such as "and the other one?" goes on from; then the last document listed, which is counted among those
    /// not shown. Nil when nothing is left to leave out.
    mutating func less(of context: TaskContext) -> TaskContext? {
        var less = context
        if less.conversation.count > 1 {
            less.conversation.removeFirst()
            exchangesLeftOut += 1
        } else if let last = less.documents.lastIndex(where: { $0.text != nil }) {
            less.documents[last].text = nil
            textsLeftOut += 1
        } else if !less.conversation.isEmpty {
            less.conversation.removeFirst()
            exchangesLeftOut += 1
        } else if !less.documents.isEmpty {
            less.documents.removeLast()
            less.unlisted += 1
            namesLeftOut += 1
        } else {
            return nil
        }
        return less
    }
}
