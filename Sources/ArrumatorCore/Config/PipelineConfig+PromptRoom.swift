import Foundation

extension PipelineConfig {
    /// A search task's request and a question are each read with what their context holds beside the answer's length
    /// (`numCtx` less the effort's `numPredict`), at `ollama.charsPerToken` characters a token: a question of
    /// `conversation.maxQuestionChars` fits it.
    var promptRoomProblems: [String] {
        var problems: [String] = []
        for (effort, preset) in tasks.efforts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where preset.numPredict >= analysis.numCtx {
            problems.append("tasks.efforts.\(effort.rawValue).numPredict leaves no room in analysis.numCtx, which a request is read with")
        }
        if ollama.refitAttempts < 0 { problems.append("ollama.refitAttempts cannot be negative") }
        guard ollama.charsPerToken.isFinite, ollama.charsPerToken > 0 else { return problems + ["ollama.charsPerToken must be more than 0"] }
        for (effort, preset) in conversation.efforts.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where Double(conversation.numCtx - preset.numPredict) * ollama.charsPerToken < Double(conversation.maxQuestionChars) {
            problems.append("conversation.efforts.\(effort.rawValue) leaves less room in conversation.numCtx than a question of "
                + "conversation.maxQuestionChars takes at ollama.charsPerToken")
        }
        return problems
    }
}
