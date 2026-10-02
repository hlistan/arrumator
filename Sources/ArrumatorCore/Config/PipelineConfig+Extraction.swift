import Foundation

extension PipelineConfig {
    /// What extraction is given for a file under `settings`: its tunables, and the vision model of the profile in use when
    /// images may be described. The ingest pipeline and `arrumatorcli ingest --dry-run` extract alike with it.
    public func extractionContext(settings: AppSettings) throws -> ExtractionContext {
        ExtractionContext(config: extraction, entities: entities, vision: settings.enableVLM ? try visionOptions(settings: settings) : nil)
    }

    /// Images are described with the context and keep-alive documents are read with (`analysis.numCtx`,
    /// `ollama.keepAlive.chat`): a profile that reads and describes images with one model keeps it loaded once, rather
    /// than Ollama loading it again with another context for every image. The model thinks as it does reading a
    /// document (`analysis.think`).
    private func visionOptions(settings: AppSettings) throws -> VisionModelOptions {
        VisionModelOptions(model: try settings.modelProfile().visionModel, keepAlive: ollama.keepAlive.chat,
                           numPredict: analysis.vlmNumPredict, numCtx: analysis.numCtx, options: analysis.llmOptions,
                           think: analysis.think)
    }
}
