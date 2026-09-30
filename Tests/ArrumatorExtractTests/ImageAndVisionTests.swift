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
        let registry = try TestConfig.registry(ollama: MockOllama(capabilities: MockOllama.visionCapabilities) { _ in
            throw OllamaError.unreachable("must not be called")
        })
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(vision: TestConfig.visionOptions()),
                                                 trace: .disabled)
        #expect(content.kind == .image, "a JPEG is read as an image")
        #expect(content.textOrigin == .ocr, "a photo with text is read by OCR (\(content.warningSummary))")
        #expect(content.text.contains("Farmácia Central"), "the shop name on the receipt is read by OCR")
        #expect(content.language.primary == "pt", "OCR text in Portuguese is detected as Portuguese")
        #expect(content.visual == nil, "an image with enough text is not sent to the vision model")
        #expect(content.metadata["exif:DateTimeOriginal"] == "2023-07-14", "the EXIF capture date is kept, in ISO form")
        #expect(content.entities.documentDate?.date == "2023-07-14", "with no date in its text, a photo is dated when it was taken")
        #expect(content.entities.documentDate?.source == .exif, "the date is known to come from EXIF, not from the text")
        #expect(content.ocr?.pages == [1], "the OCR statistics cover the one image")
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
        let content = try await TestConfig.registry(ollama: ollama).extract(url, sha256: "x", context: context,
                                                                          trace: TraceContext(traceID: 3, sink: sink))
        let visual = try #require(content.visual)
        #expect(visual.imageKind == .receipt, "the model's image kind is kept")
        #expect(visual.organisations == ["Continente"], "an organisation the OCR text shows is verified")
        #expect(visual.unverifiedOrganisations == ["Acme Corp"], "an organisation the OCR text does not show is kept apart as unverified")
        #expect(visual.dates == ["2025-01-02"], "the model's ISO dates are kept")
        #expect(content.textOrigin == .ocr, "sparse text is still read by OCR (\(content.warningSummary))")
        #expect(!content.hasWarning(.vlmFailed), "a reply wrapped in thinking tags is still a valid answer")

        let requests = await ollama.chatRequests
        let request = try #require(requests.first)
        #expect(requests.count == 1, "each image is described once")
        #expect(request.model == vision.model, "the configured vision model is asked")
        #expect(request.think == false, "a model that can think is asked not to")
        #expect(request.keepAlive == vision.keepAlive, "the model stays loaded for as long as configured")
        #expect(request.options["num_predict"] == .number(Double(vision.numPredict)), "the answer length is capped as configured")
        #expect(request.options["num_ctx"] == .number(Double(vision.numCtx)),
                "asked with the context its model is loaded with for decisions, the model is not loaded again for each image")
        #expect(request.options["temperature"] == .number(vision.options.temperature), "the model is sampled with the pipeline's temperature")
        let kinds = request.format?["properties"]?["image_kind"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(kinds == ["photo", "screenshot", "scanned_document", "receipt", "id_card", "whiteboard", "diagram", "other"], "the schema limits the image kind to the kinds Arrumator knows")
        let required = request.format?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Set(required) == ["image_kind", "description", "visible_text_summary", "organisations", "dates"], "the schema requires every field the summary needs")
        let base64 = try #require(request.messages.last?.images?.first)
        let jpeg = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(decoded.width, decoded.height) <= context.config.image.vlmMaxPixel, "the image is scaled down before it is sent to the model")

        let stages = await sink.steps.map(\.stage)
        #expect(stages == [.ocr, .vlm, .extract, .entities], "the vision model runs after OCR, and both are traced")
        let vlmStep = try #require(await sink.steps.first { $0.stage == .vlm })
        let vlmOutput = try #require(vlmStep.output)
        let vlmInput = try #require(vlmStep.input)
        #expect(vlmOutput.contains("Acme Corp"), "the trace shows what the model answered, unverified names included")
        #expect(vlmInput.contains("image_kind"), "the trace shows the schema the model was asked with")
    }

    @Test("An image without text becomes vlmOnly; thinking stays unset for models without it")
    func vlmOnly() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImage("blank.png", try Scratch.textImage([], width: 800, height: 600))
        let reply = #"{"image_kind":"photo","description":"An empty white surface","visible_text_summary":"","organisations":["Ghost Inc"],"dates":[]}"#
        let ollama = MockOllama(capabilities: ["completion", "vision"]) { _ in reply }
        let content = try await TestConfig.registry(ollama: ollama).extract(
            url, sha256: "x", context: try TestConfig.context(vision: TestConfig.visionOptions()), trace: .disabled)
        #expect(content.textOrigin == .vlmOnly, "an image without text is described by the vision model alone")
        #expect(content.visual?.organisations == [], "with no text to verify against, no organisation is verified")
        #expect(content.visual?.unverifiedOrganisations == ["Ghost Inc"], "the model's organisation is kept as unverified")
        #expect(await ollama.chatRequests.first?.think == nil, "a model without thinking is not sent the think flag")
        #expect(!content.hasWarning(.emptyText), "an image the vision model described is not reported as empty")
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
            let content = try await TestConfig.registry(ollama: ollama).extract(
                url, sha256: "x", context: context, trace: .disabled)
            #expect(content.hasWarning(.vlmFailed), "an unreachable model or a reply that is not JSON is a warning (\(content.warningSummary))")
            #expect(content.visual == nil, "a failed description leaves no visual summary behind")
            #expect(content.textOrigin == .none, "an image with no text and no description has no text origin")
        }
        let unconfigured = try await TestConfig.registry().extract(url, sha256: "x", context: try TestConfig.context(),
                                                                 trace: .disabled)
        #expect(unconfigured.hasWarning(.vlmSkipped), "without a vision model, the trace says the description was skipped")
    }

    @Test("Organisation verification ignores case and diacritics")
    func verification() throws {
        let summary = try VisionDescriber.parse(
            #"{"image_kind":"id_card","description":"d","visible_text_summary":"s","organisations":["Farmacia São João","Банк"],"dates":[]}"#,
            ocrText: "FARMÁCIA SAO   JOÃO\nLisboa")
        #expect(summary.organisations == ["Farmacia São João"], "a name matches the OCR text whatever its case, accents and spacing")
        #expect(summary.unverifiedOrganisations == ["Банк"], "a name missing from the OCR text is unverified")
        #expect(summary.imageKind == .idCard, "the snake_case kind in the reply maps to its case")
        #expect(throws: VisionDescriber.ParseError.self, "a reply without JSON is a parse error, not an empty summary") { try VisionDescriber.parse("no json here", ocrText: "") }
    }
}
