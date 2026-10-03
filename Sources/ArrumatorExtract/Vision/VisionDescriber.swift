import ArrumatorCore
import Foundation

/// What the vision model said about an image, plus everything needed for the `vlm` trace step.
struct VisionOutcome: Sendable {
    var summary: VisualSummary?
    var model: String
    /// What the model was told about thinking (`think`); nil when nothing was sent and it thought as it does by default.
    var think: OllamaThink?
    var imageBytes: Int
    var rawResponse: String?
    var metrics: OllamaMetrics?
    var error: String?
    /// What kept the model from being asked, or from answering, that passes: Ollama away. The image is described when
    /// it is read again, so its job waits for this rather than filing it without a description for good.
    var waitsFor: OllamaError?
    var durationMs: Double
}

/// What the vision model is told, from this module's `Prompts/image-system.md` and `image-user.md`.
struct VisionPrompts: Sendable {
    let system: String
    let user: String

    static func bundled() throws -> VisionPrompts {
        let templates = try PromptTemplates.bundled(["image-system", "image-user"], in: .module)
        return VisionPrompts(system: try templates.render("image-system", [:]), user: try templates.render("image-user", [:]))
    }
}

/// Describes images with a local multimodal model through `OllamaAPI` (localhost only). The response is
/// constrained by a JSON schema; organisations the model names are kept only when the OCR text contains them,
/// otherwise they are reported as unverified. A failure is returned in `VisionOutcome.error`, and one that passes,
/// Ollama away, in `waitsFor` too; only cancellation is thrown.
actor VisionDescriber {
    private let ollama: any OllamaAPI
    private let prompts: VisionPrompts
    private let time: any TimeSource
    /// What each model's `/api/show` said, which decides what it is told about thinking.
    private var shown: [String: OllamaShowResponse] = [:]

    init(ollama: any OllamaAPI, prompts: VisionPrompts, time: any TimeSource) {
        self.ollama = ollama
        self.prompts = prompts
        self.time = time
    }

    func describe(jpeg: Data, ocrText: String, options: VisionModelOptions, timeout: Double) async throws -> VisionOutcome {
        let started = Date()
        var outcome = VisionOutcome(summary: nil, model: options.model, think: nil,
                                    imageBytes: jpeg.count, rawResponse: nil, metrics: nil, error: nil, durationMs: 0)
        let ollama = ollama
        do {
            let think = try await think(options.think, to: options.model)
            outcome.think = think
            let request = Self.request(jpeg: jpeg, options: options, prompts: prompts, think: think)
            let response = try await Deadline.run(timeout, time: time, expired: { DeadlineExceeded(seconds: timeout) }) {
                try await ollama.chat(request)
            }
            outcome.rawResponse = response.message.content
            outcome.metrics = response.metrics
            outcome.summary = try Self.parse(response.message.content, ocrText: ocrText)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OllamaError where error.isTransient {
            outcome.error = error.localizedDescription
            outcome.waitsFor = error
        } catch let error as DeadlineExceeded {
            outcome.error = "vision model timed out after \(error.seconds) s"
        } catch {
            outcome.error = String(describing: error)
        }
        outcome.durationMs = started.elapsedMs
        return outcome
    }

    /// What `model` is told about thinking when `wanted` (`VisionModelOptions.think`, `analysis.think`): what its
    /// `/api/show` allows of it (`OllamaShowResponse.think(sending:)`). What the model said is cached per model. Ollama
    /// away and a stop are thrown, as asking would fail on them too; any other failed lookup tells the model nothing,
    /// and is tried again next time.
    private func think(_ wanted: OllamaThink, to model: String) async throws -> OllamaThink? {
        if let cached = shown[model] { return cached.think(sending: wanted) }
        let show: OllamaShowResponse
        do {
            show = try await ollama.show(model: model)
        } catch let error as OllamaError where error.isTransient {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        shown[model] = show
        return show.think(sending: wanted)
    }

    // MARK: Request

    static func request(jpeg: Data, options: VisionModelOptions, prompts: VisionPrompts, think: OllamaThink?) -> OllamaChatRequest {
        let llm = options.options
        return OllamaChatRequest(
            model: options.model,
            messages: [.system(prompts.system), .user(prompts.user, images: [jpeg.base64EncodedString()])],
            format: schema,
            options: [
                "temperature": .number(llm.temperature),
                "top_k": .number(Double(llm.topK)),
                "top_p": .number(llm.topP),
                "seed": .number(Double(llm.seed)),
                "num_predict": .number(Double(options.numPredict)),
                "num_ctx": .number(Double(options.numCtx)),
            ],
            keepAlive: options.keepAlive,
            think: think,
            timeout: nil)
    }

    static let schema: JSONValue = [
        "type": "object",
        "properties": [
            "image_kind": ["type": "string", "enum": .array(ImageKind.allCases.map { .string($0.rawValue) })],
            "description": ["type": "string"],
            "visible_text_summary": ["type": "string"],
            "organisations": ["type": "array", "items": ["type": "string"]],
            "dates": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["image_kind", "description", "visible_text_summary", "organisations", "dates"],
    ]

    // MARK: Response

    struct Response: Decodable {
        var imageKind: String
        var description: String
        var visibleTextSummary: String
        var organisations: [String]
        var dates: [String]

        enum CodingKeys: String, CodingKey {
            case imageKind = "image_kind"
            case description
            case visibleTextSummary = "visible_text_summary"
            case organisations, dates
        }
    }

    enum ParseError: Error, CustomStringConvertible {
        case noJSONObject
        case invalid(String)

        var description: String {
            switch self {
            case .noJSONObject: "vision model reply contains no JSON object"
            case let .invalid(reason): "vision model reply does not match the schema: \(reason)"
            }
        }
    }

    /// Parses the model reply (`ModelOutput.jsonObject`) and verifies organisations against the OCR text, case- and
    /// diacritic-insensitively.
    static func parse(_ content: String, ocrText: String) throws -> VisualSummary {
        let object = ModelOutput.jsonObject(content)
        guard object.hasPrefix("{") else { throw ParseError.noJSONObject }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(object.utf8))
        } catch {
            throw ParseError.invalid(String(describing: error))
        }
        let kind = ImageKind(rawValue: response.imageKind.lowercased()) ?? .other
        let haystack = fold(ocrText)
        var verified: [String] = []
        var unverified: [String] = []
        for name in response.organisations.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).uniqued()
        where !name.isEmpty {
            let needle = fold(name)
            if !needle.isEmpty, haystack.contains(needle) { verified.append(name) } else { unverified.append(name) }
        }
        return VisualSummary(imageKind: kind, description: response.description,
                             visibleTextSummary: response.visibleTextSummary, organisations: verified,
                             unverifiedOrganisations: unverified,
                             dates: response.dates.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// Case-, diacritic- and width-insensitive form with whitespace runs collapsed, for containment checks.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
