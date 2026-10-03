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
                "asked with the context documents are read with, the model is not loaded again for each image")
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
        #expect(vlmInput.contains(#""think":false"#), "and that the model was told not to think")
    }

    @Test("An image without text becomes vlmOnly; thinking stays unset for models that cannot be told not to think")
    func vlmOnly() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImage("blank.png", try Scratch.textImage([], width: 800, height: 600))
        let reply = #"{"image_kind":"photo","description":"An empty white surface","visible_text_summary":"","organisations":["Ghost Inc"],"dates":[]}"#
        let vision = try TestConfig.visionOptions()
        let cannotThink = MockOllama(capabilities: ["completion", "vision"]) { _ in reply }
        let thinksAtLevels = MockOllama(capabilities: MockOllama.visionCapabilities, modelThinking: [vision.model: .levels]) { _ in reply }
        for (ollama, model) in [(cannotThink, "a model without thinking"), (thinksAtLevels, "a model that names levels but not off")] {
            let sink = MemoryTraceSink()
            let content = try await TestConfig.registry(ollama: ollama).extract(
                url, sha256: "x", context: try TestConfig.context(vision: vision), trace: TraceContext(traceID: 4, sink: sink))
            #expect(content.textOrigin == .vlmOnly, "an image without text is described by the vision model alone")
            #expect(content.visual?.organisations == [], "with no text to verify against, no organisation is verified")
            #expect(content.visual?.unverifiedOrganisations == ["Ghost Inc"], "the model's organisation is kept as unverified")
            #expect(await ollama.chatRequests.first?.think == nil, "\(model) is not sent the think flag, so it thinks as it does by default")
            let input = try #require(await sink.steps.first { $0.stage == .vlm }?.input)
            #expect(!input.contains(#""think""#), "\(model): the trace says it was told nothing about thinking")
            #expect(!content.hasWarning(.emptyText), "an image the vision model described is not reported as empty")
        }
    }

    @Test("The vision model is told about thinking what the options say, analysis.think, as the model allows")
    func vlmThinking() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImage("blank.png", try Scratch.textImage([], width: 800, height: 600))
        let reply = #"{"image_kind":"photo","description":"An empty white surface","visible_text_summary":"","organisations":[],"dates":[]}"#
        var vision = try TestConfig.visionOptions()
        #expect(vision.think == (try TestConfig.pipeline()).analysis.think, "the pipeline's options carry analysis.think")
        let told: [(wanted: OllamaThink, sent: OllamaThink, why: String)] = [
            (false, false, "off, as documents are read"), (true, true, "on, when analysis.think says so"),
            ("high", true, "and a level as on, to a model that is only switched on and off"),
        ]
        for (wanted, sent, why) in told {
            vision.think = wanted
            let ollama = MockOllama(capabilities: MockOllama.visionCapabilities, modelThinking: [vision.model: .switches]) { _ in reply }
            let sink = MemoryTraceSink()
            _ = try await TestConfig.registry(ollama: ollama).extract(url, sha256: "x", context: try TestConfig.context(vision: vision),
                                                                      trace: TraceContext(traceID: 5, sink: sink))
            #expect(await ollama.chatRequests.map(\.think) == [sent], "the model is told \(why)")
            let input = try #require(await sink.steps.first { $0.stage == .vlm }?.input)
            #expect(input.contains(#""think":\#(JSON.string(sent))"#), "and the trace says what it was told: \(input)")
        }
    }

    @Test("A description the model fails to give is a warning; Ollama away or a stop is thrown, so the image waits for it")
    func vlmFailures() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImage("blank.png", try Scratch.textImage([], width: 800, height: 600))
        let context = try TestConfig.context(vision: TestConfig.visionOptions())
        let failures: [(MockOllama.ChatHandler, String)] = [({ _ in "I cannot answer that" }, "a reply that is not JSON"),
                                                            ({ _ in throw OllamaError.http(status: 400, body: "bad image") }, "a request the server refuses")]
        for (handler, failure) in failures {
            let ollama = MockOllama(capabilities: MockOllama.visionCapabilities, handler: handler)
            let content = try await TestConfig.registry(ollama: ollama).extract(
                url, sha256: "x", context: context, trace: .disabled)
            #expect(content.hasWarning(.vlmFailed), "\(failure) is a warning (\(content.warningSummary))")
            #expect(content.visual == nil, "a failed description leaves no visual summary behind")
            #expect(content.textOrigin == .none, "an image with no text and no description has no text origin")
        }

        let away = MockOllama(capabilities: MockOllama.visionCapabilities) { _ in throw OllamaError.unreachable("connection refused") }
        let sink = MemoryTraceSink()
        await #expect(throws: OllamaError.unreachable("connection refused"),
                      "Ollama away is the job's to wait for, not a reason to file the image without its description for good") {
            _ = try await TestConfig.registry(ollama: away).extract(url, sha256: "x", context: context, trace: TraceContext(traceID: 6, sink: sink))
        }
        let vlm = try #require(await sink.steps.first { $0.stage == .vlm }, "the request that failed is in the trace")
        #expect(vlm.error?.contains("not reachable") == true, "with why it failed: \(vlm.error ?? "")")
        let shown = try await TestConfig.registry(ollama: away).extract(
            url, sha256: "x", context: try TestConfig.context(vision: TestConfig.visionOptions(), whenOllamaIsAway: .note), trace: .disabled)
        #expect(shown.warnings.contains { $0.code == .vlmFailed && $0.detail.hasPrefix("Ollama is away") },
                "where only what is read now is shown, the image is read without its description, noted (\(shown.warningSummary))")

        let unshown = MockOllama(capabilities: MockOllama.visionCapabilities) { _ in "{}" }
        await unshown.failShowing(try TestConfig.visionOptions().model, with: .unreachable("connection refused"))
        await #expect(throws: OllamaError.unreachable("connection refused"), "so is Ollama away when the model's capabilities are asked") {
            _ = try await TestConfig.registry(ollama: unshown).extract(url, sha256: "x", context: context, trace: .disabled)
        }
        #expect(await unshown.chatRequests.isEmpty, "and the model is not asked before Ollama is back")

        let stopped = MockOllama(capabilities: MockOllama.visionCapabilities) { _ in throw CancellationError() }
        await #expect("a stop while the model describes the image stops the job, not as a warning") {
            _ = try await TestConfig.registry(ollama: stopped).extract(url, sha256: "x", context: context, trace: .disabled)
        } throws: { error in
            guard case .cancelled? = error as? ExtractionError else { return false }
            return true
        }

        let unconfigured = try await TestConfig.registry().extract(url, sha256: "x", context: try TestConfig.context(),
                                                                 trace: .disabled)
        #expect(unconfigured.hasWarning(.vlmSkipped), "without a vision model, the trace says the description was skipped")
    }

    @Test("An image that declares more pixels than extraction.image.maxPixels is read for its metadata alone, never decoded")
    func pixelBudget() async throws {
        let scratch = try Scratch()
        // 360 KB on disk, 1.6 billion pixels declared.
        let url = try scratch.writeTIFF("huge.tiff", declaring: 40_000, by: 40_000)
        let recognizer = RecordingRecognizer()
        let ollama = MockOllama(capabilities: MockOllama.visionCapabilities) { _ in throw OllamaError.unreachable("must not be called") }
        let context = try TestConfig.context(vision: TestConfig.visionOptions())
        let content = try await TestConfig.registry(ollama: ollama, recognizer: recognizer)
            .extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(content.textOrigin == .metadataOnly, "an image over the budget is described by its metadata alone")
        #expect(content.warnings.map(\.code) == [.tooLarge], "and says why (\(content.warningSummary))")
        #expect(content.metadata["image:width"] == "40000", "its declared width is kept as metadata")
        #expect(content.metadata["image:height"] == "40000", "and its declared height")
        #expect(await recognizer.widths.isEmpty, "no image is decoded for OCR")
        #expect(await ollama.chatRequests.isEmpty, "nor for the vision model")
    }

    @Test("An image of exactly extraction.image.maxPixels is read; one pixel fewer allowed, and it is not")
    func pixelBudgetBoundary() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeImage("page.png", try Scratch.textImage([], width: 800, height: 600))
        for (maxPixels, read) in [(800 * 600, true), (800 * 600 - 1, false)] {
            let recognizer = RecordingRecognizer()
            let context = try TestConfig.context { extraction, _ in extraction.image.maxPixels = maxPixels }
            let content = try await TestConfig.registry(recognizer: recognizer)
                .extract(url, sha256: "x", context: context, trace: .disabled)
            #expect(await recognizer.widths.count == (read ? 1 : 0), "with \(maxPixels) pixels allowed, an 800 × 600 image is read: \(read)")
            #expect(content.hasWarning(.tooLarge) == !read, "and only a refused one is noted as too large")
        }
    }

    /// A recognizer that reads, on each page, a sentence naming the page by its width, long enough not to be sparse.
    private static func pageReader() -> RecordingRecognizer {
        RecordingRecognizer { "Página de \($0.width) pontos: fatura de eletricidade de julho, a pagar até ao fim de agosto." }
    }

    @Test("Every page of a multi-page TIFF is read, in order, as a scanned PDF's pages are")
    func multiPageTIFF() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeTIFF("fax.tiff", pages: try [700, 800, 900].map { try Scratch.textImage([], width: $0, height: 500) })
        let recognizer = Self.pageReader()
        let content = try await TestConfig.registry(recognizer: recognizer)
            .extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(await recognizer.widths == [700, 800, 900], "each page is read once, in the order of the file")
        let pages = ["700", "800", "900"].map { "Página de \($0) pontos" }
        let offsets = try pages.map { try #require(content.text.range(of: $0), "page \($0) is in the text").lowerBound }
        #expect(offsets == offsets.sorted(), "the pages' text comes in the order of the pages")
        #expect(content.pageCount == 3, "the image is counted as the three pages it has")
        #expect(content.pagesOCRed == [1, 2, 3], "and each was read by OCR")
        #expect(!content.hasWarning(.textTruncated), "nothing was left out (\(content.warningSummary))")
    }

    @Test("A TIFF longer than extraction.pdf.ocrAllIfAtMost has its first ocrHeadPages and its last page read, and says so")
    func longTIFF() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeTIFF("scan.tiff", pages: try [700, 800, 900].map { try Scratch.textImage([], width: $0, height: 500) })
        let recognizer = Self.pageReader()
        let context = try TestConfig.context { extraction, _ in
            extraction.pdf.ocrAllIfAtMost = 2
            extraction.pdf.ocrHeadPages = 1
        }
        let content = try await TestConfig.registry(recognizer: recognizer).extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(await recognizer.widths == [700, 900], "the first page and the last are read, as a long scanned PDF's are")
        #expect(content.pagesOCRed == [1, 3], "and they are the pages OCR read")
        #expect(content.warnings.filter { $0.code == .textTruncated }.map(\.detail) == ["read 2 of 3 pages"],
                "the page left out is noted, so the model knows it saw part of the document")
    }

    @Test("Words are counted in every script, so a receipt in Chinese or Japanese is no sparser than one in Portuguese")
    func sparseInEveryScript() throws {
        let config = try TestConfig.pipeline().extraction.image
        let receipts = [
            ("Chinese", "北京市朝阳区超市购物小票，商品名称：牛奶两盒，面包一袋，苹果三斤，鸡蛋一盒。合计金额人民币八十六元五角，现金支付一百元，找零十三元五角，欢迎再次光临本店，谢谢惠顾。"),
            ("Japanese", "東京都渋谷区のスーパーマーケットの領収書です。牛乳二本、食パン一斤、りんご三個、卵一パックをお買い上げいただきました。合計金額は千二百八十円、お預かり二千円、お釣りは七百二十円です。"),
            ("Portuguese", "Continente Bom Dia Lisboa, talão de compra: leite meio-gordo, pão de forma, maçãs e ovos. Total a pagar 12,80 euros."),
        ]
        for (script, text) in receipts {
            #expect(!ImageExtractor.isSparse(text: text, confidence: 0.9, config: config),
                    "a receipt in \(script) that OCR read whole is not sent to the vision model")
        }
        #expect(ImageExtractor.isSparse(text: "CONTINENTE", confidence: 0.9, config: config), "a logo alone is sparse")
        #expect(ImageExtractor.isSparse(text: "東京電力", confidence: 0.9, config: config), "and so is a name alone, in any script")
        // Ten runs between spaces, enough characters, and six words: rules and stars are no words.
        let banner = "*** TOTAL A PAGAR *** 1.234,80 EUR " + String(repeating: "-", count: 40) + " OBRIGADO " + String(repeating: "=", count: 30)
        #expect(banner.split(separator: " ").count >= config.sparseWords && banner.count { !$0.isWhitespace } >= config.sparseChars,
                "counted at its spaces, the banner would not be sparse")
        #expect(ImageExtractor.isSparse(text: banner, confidence: 0.9, config: config),
                "a picture whose words are few, however many symbols stand between them, is described by the vision model")
    }

    @Test("A vision model's deadline of no time at all is refused by name, as it would wait for ever", arguments: [0.0, -1.0])
    func vlmTimeoutRefused(seconds: Double) throws {
        var config = try TestConfig.pipeline()
        config.extraction.image.vlmTimeout = seconds
        #expect(config.problems == ["extraction.image.vlmTimeout must be more than 0"], "\(seconds) s: \(config.problems)")
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
