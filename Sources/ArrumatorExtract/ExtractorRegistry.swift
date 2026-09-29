import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// Turns any file into `ExtractedContent` using on-device facilities only.
///
/// Resolves the file's type (extension → file-system content type → magic bytes), dispatches to the per-format
/// extractor (exact type match first, then the most specific conformance; previewable unknown types go through
/// Quick Look) under `ExtractionConfig.perFileTimeout`, then NFC-normalises and caps the text, detects the
/// language, extracts entities and resolves the document date. Files above `largeFileBytes` are metadata-only.
/// Soft problems become warnings; `ExtractionError` is thrown only for unreadable files, timeouts and
/// cancellation. Records `extract` and `entities` trace steps (extractors add `ocr` and `vlm`).
public struct ExtractorRegistry: ContentExtracting {
    private let extractors: [any FileExtractor]
    private let previewer: QuickLookExtractor
    private let metadataOnly = MetadataOnlyExtractor()

    /// - Parameter ollama: local Ollama client used to describe images with sparse text; without it such images
    ///   get a `vlmSkipped` warning.
    public init(ollama: (any OllamaAPI)? = nil) {
        let ocr = OCRService(recognizer: VisionTextRecognizer())
        let vision = ollama.map { VisionDescriber(ollama: $0) }
        previewer = QuickLookExtractor(ocr: ocr, metadataOnly: metadataOnly)
        extractors = [
            PDFExtractor(ocr: ocr),
            ImageExtractor(ocr: ocr, vision: vision),
            PlainTextExtractor(),
            TextutilExtractor(shell: ShellRunner()),
            XLSXExtractor(),
            PPTXExtractor(),
            EmailExtractor(),
            ArchiveExtractor(),
            MediaExtractor(),
            previewer,
        ]
    }

    public func extract(_ url: URL, sha256: String, context: ExtractionContext,
                        trace: TraceContext) async throws -> ExtractedContent {
        let started = Date()
        guard !Task.isCancelled else { throw ExtractionError.cancelled }
        let inspected = try SourceInspector.inspect(url, sha256: sha256)
        let config = context.config
        let tooLarge = inspected.source.byteSize > config.largeFileBytes
        let extractor: any FileExtractor = tooLarge ? metadataOnly : extractor(for: inspected.type)
        let job = ExtractionJob(url: url, source: inspected.source, type: inspected.type, context: context, trace: trace)
        let input = ExtractTraceInput(filename: inspected.source.originalFilename, utType: inspected.type.identifier,
                                      byteSize: inspected.source.byteSize, whereFroms: inspected.source.whereFroms,
                                      extractor: extractor.name, extractorVersion: extractor.version,
                                      timeoutSeconds: config.perFileTimeout)

        let draft: ExtractionDraft
        let used: any FileExtractor
        if tooLarge {
            draft = metadataOnly.draft(for: job, warnings: [
                ExtractionWarning(.tooLarge, "\(inspected.source.byteSize) bytes > \(config.largeFileBytes)"),
            ])
            used = metadataOnly
        } else {
            do {
                draft = try await Deadline.run(seconds: config.perFileTimeout) { try await extractor.extract(job) }
                used = extractor
            } catch {
                if let failure = Self.hardFailure(error, extractor: extractor) {
                    await trace.record(.extract, status: .error, startedAt: started, input: input,
                                       error: failure.localizedDescription)
                    Log.error(.extract, "Extraction failed", [
                        "file": inspected.source.originalFilename, "extractor": extractor.name,
                        "error": failure.localizedDescription,
                    ])
                    throw failure
                }
                Log.warning(.extract, "Extractor failed; continuing metadata-only", [
                    "file": inspected.source.originalFilename, "extractor": extractor.name,
                    "error": String(describing: error),
                ])
                draft = metadataOnly.draft(for: job, warnings: [ExtractionWarning(.corrupted, String(describing: error))])
                used = metadataOnly
            }
        }
        return await finish(draft, extractor: used, input: input, inspected: inspected, context: context,
                            trace: trace, started: started)
    }

    // MARK: Dispatch

    /// Exact type match first, then the extractor whose matching supported type is most specific; Quick Look for
    /// everything else.
    func extractor(for type: UTType) -> any FileExtractor {
        if let exact = extractors.first(where: { $0.supportedTypes.contains(type) }) { return exact }
        var best: (extractor: any FileExtractor, depth: Int)?
        for extractor in extractors {
            for supported in extractor.supportedTypes where type.conforms(to: supported) {
                let depth = supported.supertypes.count
                if depth > best?.depth ?? -1 { best = (extractor, depth) }
            }
        }
        return best?.extractor ?? previewer
    }

    /// Maps thrown errors to the hard failures that fail the job; `nil` means "soft: continue metadata-only".
    private static func hardFailure(_ error: any Error, extractor: any FileExtractor) -> ExtractionError? {
        switch error {
        case let error as ExtractionError: error
        case is CancellationError: .cancelled
        case is DeadlineExceeded: .timeout(stage: "extract:\(extractor.name)")
        default: nil
        }
    }

    // MARK: Assembly

    private func finish(_ draft: ExtractionDraft, extractor: any FileExtractor, input: ExtractTraceInput,
                        inspected: InspectedFile, context: ExtractionContext, trace: TraceContext,
                        started: Date) async -> ExtractedContent {
        let config = context.config
        var warnings = draft.warnings
        var timings = draft.timings
        timings["extract"] = started.elapsedMs

        let normalized = TextNormalizer.normalize(draft.text)
        let (text, truncated) = TextNormalizer.cap(normalized, maxChars: config.maxIndexChars)
        if truncated {
            warnings.append(ExtractionWarning(.textTruncated, "kept \(config.maxIndexChars) of \(normalized.count) characters"))
        }
        let expectsText: Set<TextOrigin> = [.textLayer, .ocr, .mixed, .none]
        if text.isEmpty, draft.visual == nil, expectsText.contains(draft.textOrigin) {
            warnings.append(ExtractionWarning(.emptyText))
        }

        let languageStarted = Date()
        let language = LanguageDetector(config: config).detect(text)
        timings["language"] = languageStarted.elapsedMs

        let entitiesStarted = Date()
        let scan = EntityExtractor(config: context.entities).scan(text)
        let evidence = DateEvidence(firstPageLength: draft.firstPageLength, metadataDates: draft.metadataDates,
                                    fileCreated: inspected.source.createdAt, fileModified: inspected.source.modifiedAt)
        let resolution = DocumentDateResolver(config: context.entities).resolve(scan.dateCandidates, in: text,
                                                                                evidence: evidence)
        let entities = Entities(dates: resolution.ranked, documentDate: resolution.chosen, amounts: scan.amounts,
                                emails: scan.emails, urls: scan.urls, phones: scan.phones, stableKeys: scan.stableKeys)
        timings["entities"] = entitiesStarted.elapsedMs
        timings["total"] = started.elapsedMs

        let content = ExtractedContent(
            source: inspected.source, kind: draft.kind, textOrigin: draft.textOrigin, text: text,
            textTruncated: truncated, pageCount: draft.pageCount, pagesOCRed: draft.pagesOCRed, ocr: draft.ocr,
            language: language, entities: entities, structure: draft.structure, metadata: draft.metadata,
            visual: draft.visual, attachments: draft.attachments, warnings: warnings, timings: timings,
            extractorName: extractor.name, extractorVersion: extractor.version)

        let previewChars = config.tracePreviewChars
        await trace.record(.extract, status: warnings.isEmpty ? .ok : .warn, startedAt: started, input: input,
                           output: ExtractTraceOutput(
                               kind: content.kind, textOrigin: content.textOrigin, extractedLength: normalized.count,
                               textLength: text.count, textTruncated: truncated,
                               preview: TextNormalizer.preview(text, maxChars: previewChars),
                               pageCount: content.pageCount, pagesOCRed: content.pagesOCRed, ocr: content.ocr,
                               encoding: content.metadata["text:encoding"], language: language,
                               metadata: content.metadata.mapValues { TextNormalizer.preview($0, maxChars: previewChars) },
                               attachments: content.attachments.count, structure: content.structure,
                               visualKind: content.visual?.imageKind, warnings: warnings, timings: timings))
        if trace.isEnabled {
            let input = EntitiesTraceInput(textLength: text.count, firstPageLength: draft.firstPageLength,
                                           metadataDates: draft.metadataDates, fileCreated: inspected.source.createdAt,
                                           fileModified: inspected.source.modifiedAt)
            let output = EntitiesTraceOutput(
                dateCandidates: resolution.scored, chosen: resolution.chosen,
                stableKeys: entities.stableKeys.map(\.token), amounts: entities.amounts.count,
                currencies: entities.amounts.map(\.currency).uniqued(),
                emailDomains: entities.emails.compactMap { $0.split(separator: "@").last.map(String.init) }.uniqued(),
                urls: entities.urls.count, phones: entities.phones.count)
            await trace.record(TraceStep(stage: .entities, startedAt: entitiesStarted,
                                         durationMs: timings["entities"] ?? 0,
                                         input: JSON.string(input), output: JSON.string(output)))
        }

        Log.info(.extract, "Extracted", [
            "file": inspected.source.originalFilename, "extractor": extractor.name, "kind": content.kind.rawValue,
            "origin": content.textOrigin.rawValue, "chars": String(text.count), "language": language.primary,
            "date": resolution.chosen.map { "\($0.date) (\($0.source.rawValue))" } ?? "-",
            "keys": String(entities.stableKeys.count),
            "warnings": warnings.map(\.code.rawValue).joined(separator: ","),
            "ms": String(Int(timings["total"] ?? 0)),
        ])
        return content
    }
}
