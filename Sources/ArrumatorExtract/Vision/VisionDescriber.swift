import ArrumatorCore
import Foundation

/// What the vision model said about an image, plus everything needed for the `vlm` trace step.
struct VisionOutcome: Sendable {
    var summary: VisualSummary?
    var model: String
    var thinkDisabled: Bool
    var imageBytes: Int
    var rawResponse: String?
    var metrics: OllamaMetrics?
    var error: String?
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
/// otherwise they are reported as unverified. Never throws: failures are returned in `VisionOutcome.error`.
actor VisionDescriber {
    private let ollama: any OllamaAPI
    private let prompts: VisionPrompts
    private let time: any TimeSource
    private var thinkingSupport: [String: Bool] = [:]

    init(ollama: any OllamaAPI, prompts: VisionPrompts, time: any TimeSource) {
        self.ollama = ollama
        self.prompts = prompts
        self.time = time
    }

    func describe(jpeg: Data, ocrText: String, options: VisionModelOptions, timeout: Double) async -> VisionOutcome {
        let started = Date()
        let supportsThinking = await thinking(options.model)
        let request = Self.request(jpeg: jpeg, options: options, prompts: prompts, disableThinking: supportsThinking)
        var outcome = VisionOutcome(summary: nil, model: options.model, thinkDisabled: supportsThinking,
                                    imageBytes: jpeg.count, rawResponse: nil, metrics: nil, error: nil, durationMs: 0)
        let ollama = ollama
        do {
            let response = try await Deadline.run(timeout, time: time, expired: { DeadlineExceeded(seconds: timeout) }) {
                try await ollama.chat(request)
            }
            outcome.rawResponse = response.message.content
            outcome.metrics = response.metrics
            outcome.summary = try Self.parse(response.message.content, ocrText: ocrText)
        } catch let error as DeadlineExceeded {
            outcome.error = "vision model timed out after \(error.seconds) s"
        } catch {
            outcome.error = String(describing: error)
        }
        outcome.durationMs = started.elapsedMs
        return outcome
    }

    /// Whether `model` reports the thinking capability (then `think: false` is sent). Cached per model; a failed
    /// lookup is treated as "no thinking" and retried next time.
    private func thinking(_ model: String) async -> Bool {
        if let cached = thinkingSupport[model] { return cached }
        guard let show = try? await ollama.show(model: model) else { return false }
        thinkingSupport[model] = show.supportsThinking
        return show.supportsThinking
    }

    // MARK: Request

    static func request(jpeg: Data, options: VisionModelOptions, prompts: VisionPrompts, disableThinking: Bool) -> OllamaChatRequest {
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
            think: disableThinking ? false : nil)
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
