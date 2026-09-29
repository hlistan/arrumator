import ArrumatorCore
@testable import ArrumatorExtract
import ArrumatorTesting
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("Images, OCR and the vision model")
struct ImageAndVisionTests {
    @Test("Image OCR with EXIF capture date as fallback document date", .enabled(VisionOCR.unavailable) { await VisionOCR.available.value })
    func imageOCR() async throws {
        let scratch = try Scratch()
        let image = try Scratch.textImage([
            "Recibo de pagamento", "Farmácia Central, Lisboa", "Medicamentos e produtos de saúde",
            "Obrigado pela sua visita e volte sempre",
        ], width: 1400, height: 900)
        let url = try scratch.writeImage("recibo.jpg", image, type: .jpeg, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2023:07:14 10:31:00"],
        ])
        let registry = ExtractorRegistry(ollama: MockOllama(capabilities: MockOllama.visionCapabilities) { _ in
            throw OllamaError.unreachable("must not be called")
        })
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(vision: TestConfig.visionOptions()),
                                                 trace: .disabled)
        #expect(content.kind == .image)
        #expect(content.textOrigin == .ocr, "a photo with text is read by OCR (\(content.warningSummary))")
        #expect(content.text.contains("Farmácia Central"))
        #expect(content.language.primary == "pt")
        #expect(content.visual == nil)
        #expect(content.metadata["exif:DateTimeOriginal"] == "2023-07-14")
        #expect(content.entities.documentDate?.date == "2023-07-14")
        #expect(content.entities.documentDate?.source == .exif)
        #expect(content.ocr != nil)
    }

    @Test("Sparse OCR calls the vision model with the schema; organisations are verified against OCR text", .enabled(VisionOCR.unavailable) { await VisionOCR.available.value })
    func vlmVerification() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImage("logo.png", try Scratch.textImage(["CONTINENTE"], width: 2400, height: 1600,
                                                                           fontSize: 120))
        let reply = """
        <think>internal reasoning</think>{"image_kind":"receipt","description":"A supermarket receipt header",
        "visible_text_summary":"CONTINENTE","organisations":["Continente","Acme Corp"],"dates":["2025-01-02"]}
        """
        let ollama = MockOllama(capabilities: MockOllama.visionCapabilities) { _ in reply }
        let vision = try TestConfig.visionOptions()
        let context = try TestConfig.context(vision: vision)
        let sink = MemoryTraceSink()
        let content = try await ExtractorRegistry(ollama: ollama).extract(url, sha256: "x", context: context,
                                                                          trace: TraceContext(traceID: 3, sink: sink))
        let visual = try #require(content.visual)
        #expect(visual.imageKind == "receipt")
        #expect(visual.organisations == ["Continente"])
        #expect(visual.unverifiedOrganisations == ["Acme Corp"])
        #expect(visual.dates == ["2025-01-02"])
        #expect(content.textOrigin == .ocr, "sparse text is still read by OCR (\(content.warningSummary))")
        #expect(!content.hasWarning(.vlmFailed))

        let requests = await ollama.chatRequests
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.model == vision.model)
        #expect(request.think == false)
        #expect(request.keepAlive == vision.keepAlive)
        #expect(request.options["num_predict"] == .number(Double(vision.numPredict)))
        #expect(request.options["num_ctx"] == .number(Double(vision.numCtx)),
                "asked with the context its model is loaded with for decisions, the model is not loaded again for each image")
        #expect(request.options["temperature"] == .number(vision.options.temperature))
        let kinds = request.format?["properties"]?["image_kind"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(kinds == ["photo", "screenshot", "scanned_document", "receipt", "id_card", "whiteboard", "diagram", "other"])
        let required = request.format?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Set(required) == ["image_kind", "description", "visible_text_summary", "organisations", "dates"])
        let base64 = try #require(request.messages.last?.images?.first)
        let jpeg = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(decoded.width, decoded.height) <= context.config.image.vlmMaxPixel)

        let stages = await sink.steps.map(\.stage)
        #expect(stages == [.ocr, .vlm, .extract, .entities])
        let vlmStep = try #require(await sink.steps.first { $0.stage == .vlm })
        #expect(vlmStep.output?.contains("Acme Corp") == true)
        #expect(vlmStep.input?.contains("image_kind") == true)
    }

    @Test("An image without text becomes vlmOnly; thinking stays unset for models without it")
    func vlmOnly() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImage("blank.png", try Scratch.textImage([], width: 800, height: 600))
        let reply = #"{"image_kind":"photo","description":"An empty white surface","visible_text_summary":"","organisations":["Ghost Inc"],"dates":[]}"#
        let ollama = MockOllama(capabilities: ["completion", "vision"]) { _ in reply }
        let content = try await ExtractorRegistry(ollama: ollama).extract(
            url, sha256: "x", context: try TestConfig.context(vision: TestConfig.visionOptions()), trace: .disabled)
        #expect(content.textOrigin == .vlmOnly)
        #expect(content.visual?.organisations.isEmpty == true)
        #expect(content.visual?.unverifiedOrganisations == ["Ghost Inc"])
        #expect(await ollama.chatRequests.first?.think == nil)
        #expect(!content.hasWarning(.emptyText))
    }

    @Test("Vision failures become warnings, never errors")
    func vlmFailures() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImage("blank.png", try Scratch.textImage([], width: 800, height: 600))
        let context = try TestConfig.context(vision: TestConfig.visionOptions())
        let failures: [MockOllama.ChatHandler] = [{ _ in throw OllamaError.unreachable("connection refused") },
                                                  { _ in "I cannot answer that" }]
        for handler in failures {
            let ollama = MockOllama(capabilities: MockOllama.visionCapabilities, handler: handler)
            let content = try await ExtractorRegistry(ollama: ollama).extract(
                url, sha256: "x", context: context, trace: .disabled)
            #expect(content.hasWarning(.vlmFailed))
            #expect(content.visual == nil)
            #expect(content.textOrigin == .none)
        }
        let unconfigured = try await ExtractorRegistry().extract(url, sha256: "x", context: try TestConfig.context(),
                                                                 trace: .disabled)
        #expect(unconfigured.hasWarning(.vlmSkipped))
    }

    @Test("Organisation verification ignores case and diacritics")
    func verification() throws {
        let summary = try VisionDescriber.parse(
            #"{"image_kind":"id_card","description":"d","visible_text_summary":"s","organisations":["Farmacia São João","Банк"],"dates":[]}"#,
            ocrText: "FARMÁCIA SAO   JOÃO\nLisboa")
        #expect(summary.organisations == ["Farmacia São João"])
        #expect(summary.unverifiedOrganisations == ["Банк"])
        #expect(summary.imageKind == "id_card")
        #expect(throws: VisionDescriber.ParseError.self) { try VisionDescriber.parse("no json here", ocrText: "") }
    }
}
