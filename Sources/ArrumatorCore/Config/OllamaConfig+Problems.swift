import Foundation

extension OllamaConfig {
    /// Why these settings cannot be used, if they cannot (`PipelineConfig.problems`).
    var problems: [String] {
        var problems: [String] = []
        let timeouts = [("meta", timeouts.meta), ("version", timeouts.version), ("chat", timeouts.chat), ("embed", timeouts.embed),
                        ("pull", timeouts.pull)]
        for (name, seconds) in timeouts where seconds < 0 {
            problems.append("ollama.timeouts.\(name) cannot be negative: 0 is no timeout")
        }
        if !(self.timeouts.resolve > 0) { problems.append("ollama.timeouts.resolve must be more than 0") }
        if maxResponseBytes < 1 { problems.append("ollama.maxResponseBytes must be at least 1") }
        if modelLocationMaxAge < 0 { problems.append("ollama.modelLocationMaxAge cannot be negative: 0 asks before every request") }
        // How often the server is asked whether it answers, and how long it is given to start: 0 would ask without a pause.
        problems += Limits.moreThanZero("ollama", ["healthPollStarting": healthPollStarting, "healthPollSteady": healthPollSteady,
                                                   "startTimeout": startTimeout])
        if retryDelays.contains(where: { $0 < 0 }) { problems.append("ollama.retryDelays cannot be negative") }
        if restartBackoff.all.contains(where: { $0 < 0 }) { problems.append("ollama.restartBackoff cannot be negative") }
        if failedProbesBeforeAway < 1 { problems.append("ollama.failedProbesBeforeAway must be at least 1") }
        if maxRestartsPerHour < 0 { problems.append("ollama.maxRestartsPerHour cannot be negative: 0 never starts it again") }
        if requiredFreeDiskGBAfterPull < 0 { problems.append("ollama.requiredFreeDiskGBAfterPull cannot be negative") }
        return problems
    }
}
