import ArrumatorCore
import Foundation

/// Asks the local model whether a decided folder is one that exists beside it under another name, and records each
/// question and answer in the trace. Without a valid answer it cannot tell, which the guard treats as not the same.
struct ModelFolderJudge: FolderJudge {
    let model: LLMClassifier
    let tiers: [LLMClassifier.Tier]
    let prompts: PromptBuilder
    let system: String
    let trace: TraceContext

    func isSame(_ level: FolderLevel, as folder: TaxonomyFolder, inside place: String) async throws -> Bool? {
        let started = Date()
        let input = ["decided": level.name, "existing": folder.name, "inside": place]
        let prompts = prompts
        do {
            let answer = try await model.ask(system: system, user: try prompts.judgeUser(level: level, folder: folder, place: place),
                                             schema: ClassificationSchema.sameFolder(), tiers: tiers,
                                             repairPrompt: { try prompts.repair(errors: $0) },
                                             validate: { try AnswerValidator.sameFolder($0) })
            await trace.record(.judge, status: answer.calls.count > 1 ? .warn : .ok, startedAt: started, input: input, output: answer.calls)
            return answer.answer
        } catch let error as ModelAnswerError {
            if case let .exhausted(calls) = error {
                await trace.record(.judge, status: .error, startedAt: started, input: input, output: calls, error: error.localizedDescription)
            }
            return nil
        }
    }
}
