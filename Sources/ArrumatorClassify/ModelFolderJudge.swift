import ArrumatorCore
import Foundation

/// Asks the local model which of the folders beside a decided one, if any, it is, and records each question and answer
/// in the trace. Without a valid answer it cannot tell, which the guard treats as none of them.
struct ModelFolderJudge: FolderJudge {
    let model: LLMClassifier
    let tiers: [LLMClassifier.Tier]
    let prompts: PromptBuilder
    let system: String
    /// The document being filed, as `PromptBuilder.judgedDocument` shows it: the question is where it is at home.
    let document: String
    let trace: TraceContext

    func choose(_ level: FolderLevel, among candidates: [TaxonomyFolder], inside place: String) async throws -> FolderChoice {
        let started = Date()
        let input = ["decided": level.name, "offered": candidates.map(\.name).joined(separator: "; "), "inside": place]
        let prompts = prompts
        let count = candidates.count
        do {
            let answer = try await model.ask(system: system,
                                             user: try prompts.judgeUser(level: level, candidates: candidates, place: place, document: document),
                                             schema: ClassificationSchema.folderChoice(options: count), tiers: tiers,
                                             repairPrompt: { try prompts.repair(errors: $0) },
                                             validate: { try AnswerValidator.folderChoice($0, options: count) })
            await trace.record(.judge, status: answer.calls.count > 1 ? .warn : .ok, startedAt: started, input: input, output: answer.calls)
            switch answer.answer {
            case let .option(index): return .folder(candidates[index])
            case .none: return .none
            case .unsure: return .unsure
            }
        } catch let error as ModelAnswerError {
            if case let .exhausted(calls) = error {
                await trace.record(.judge, status: .error, startedAt: started, input: input, output: calls, error: error.localizedDescription)
            }
            return .unsure
        }
    }
}
