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
        return problems
    }
}
