import Foundation

/// What the index keeps of a file as its stages read it: its text, for search by words, and its embedding, for search by
/// meaning; and a filed document's text and embedding read again after a rebuild.
extension IngestCoordinator {
    /// Reads a filed document's text and computes its embedding again, asking the model nothing and moving nothing:
    /// what a document needs for search after the index was rebuilt from the archive. Its labels come from its record.
    func reindex(_ job: inout JobRecord, payload: inout JobPayload, settings: AppSettings, trace: TraceContext) async throws {
        guard let docID = job.docId, let document = try await services.documents.document(id: docID),
              FileManager.default.fileExists(atPath: document.path) else {
            try await save(&job, &payload, state: .cancelled, trace: trace)
            return
        }
        try await save(&job, &payload, state: .extracting, trace: trace)
        let context = try services.config.extractionContext(settings: settings, whenOllamaIsAway: .wait)
        let content = try await services.extractor.extract(document.url, sha256: document.sha256, context: context, trace: trace)
        try await storeExtraction(docID: docID, content: content)
        let senders = document.labels(.sender)
        if let (vector, model) = try await services.analyzer.embedding(for: content, senders: senders, settings: settings,
                                                                        config: services.config, trace: trace) {
            try await index(docID: docID, content: content, senders: senders, vector: vector, model: model, trace: trace)
        }
        try await save(&job, &payload, state: .done, trace: trace)
    }

    func index(docID: Int64, content: ExtractedContent, senders: [String], vector: [Float], model: String,
               trace: TraceContext) async throws {
        let text = services.embeddingText(content, senders: senders)
        try await trace.measure(.index, input: ["model": model]) {
            try await services.index.upsertEmbedding(docID: docID, model: model, vector: vector, sourceText: text)
            await services.vectors.upsert(docID: docID, vector: vector, model: model)
        }
    }

    func storeExtraction(docID: Int64, content: ExtractedContent) async throws {
        let now = services.time.now()
        let doc = try await services.documents.update(docID) { doc in
            doc.pageCount = content.pageCount
            doc.extractedAt = now
            doc.contentJson = try DocumentStore.storedContentJSON(content)
        }
        try await services.index.upsertText(docID: docID, filename: doc.filename, body: content.text, summary: content.visual?.description,
                                            metadata: content.metadata, extractorVersion: content.extractedBy, labels: doc.labels ?? [])
    }

    /// Says in the trace that what reading a document again gave it took the place of what it had, in the transaction
    /// that recorded its filing (`PipelineServices.replaceReading`), with the embedding model it was made with, or that
    /// it kept its earlier embeddings, having none; and has what search by meaning holds in memory follow the index.
    func replaced(docID: Int64, outcome: AnalysisOutcome, trace: TraceContext) async {
        await trace.record(.index, startedAt: services.time.now(), durationMs: 0,
                           output: ["replaced": "labels, text, meaning", "model": outcome.embeddingModel ?? "none: the earlier embeddings kept"])
        guard let embedding = outcome.embedding, let model = outcome.embeddingModel else { return }
        await services.vectors.remove(docID: docID)
        await services.vectors.upsert(docID: docID, vector: embedding, model: model)
    }
}
