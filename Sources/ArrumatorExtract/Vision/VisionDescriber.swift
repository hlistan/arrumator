import ArrumatorCore
import Foundation

/// Image categories the vision model may return (the `image_kind` enum of the response schema).
enum ImageKind: String, CaseIterable, Sendable {
    case photo, screenshot, scannedDocument = "scanned_document", receipt, idCard = "id_card", whiteboard, diagram, other
}

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

/// Describes images with a local multimodal model through `OllamaAPI` (localhost only). The response is
/// constrained by a JSON schema; organisations the model names are kept only when the OCR text contains them,
/// otherwise they are reported as unverified. Never throws: failures are returned in `VisionOutcome.error`.
actor VisionDescriber {
    private let ollama: any OllamaAPI
    private var thinkingSupport: [String: Bool] = [:]

    init(ollama: any OllamaAPI) {
        self.ollama = ollama
    }

    func describe(jpeg: Data, ocrText: String, options: VisionModelOptions, timeout: Double) async -> VisionOutcome {
        let started = Date()
        let supportsThinking = await thinking(options.model)
        let request = Self.request(jpeg: jpeg, options: options, disableThinking: supportsThinking)
        var outcome = VisionOutcome(summary: nil, model: options.model, thinkDisabled: supportsThinking,
                                    imageBytes: jpeg.count, rawResponse: nil, metrics: nil, error: nil, durationMs: 0)
        let ollama = ollama
        do {
            let response = try await Deadline.run(seconds: timeout) { try await ollama.chat(request) }
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

    static func request(jpeg: Data, options: VisionModelOptions, disableThinking: Bool) -> OllamaChatRequest {
        let llm = options.options
        return OllamaChatRequest(
            model: options.model,
            messages: [.system(systemPrompt), .user(userPrompt, images: [jpeg.base64EncodedString()])],
            format: schema,
            options: [
                "temperature": .number(llm.temperature),
                "top_k": .number(Double(llm.topK)),
                "top_p": .number(llm.topP),
                "seed": .number(Double(llm.seed)),
                "num_predict": .number(Double(options.numPredict)),
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

    static let systemPrompt = """
    You describe images for a private, offline personal document archive. Documents are in English, Russian or \
    Portuguese. Reply with one JSON object that follows the schema and nothing else.
    - image_kind: the single best category.
    - description: what the image shows, in English, at most 40 words.
    - visible_text_summary: a short summary of the legible text, in the language it is written in; empty string \
    if there is no legible text.
    - organisations: companies, institutions, shops or brands whose names are visibly written in the image, spelled \
    exactly as written; empty list if none.
    - dates: dates visibly written in the image, as YYYY-MM-DD when unambiguous, otherwise as written.
    Never guess or invent anything that is not visible.
    """

    static let userPrompt = "Describe this image."

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

    /// Parses the model reply (stripping `<think>` blocks defensively) and verifies organisations against the OCR
    /// text, case- and diacritic-insensitively.
    static func parse(_ content: String, ocrText: String) throws -> VisualSummary {
        let stripped = content.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        guard let open = stripped.firstIndex(of: "{"), let close = stripped.lastIndex(of: "}"), open < close else {
            throw ParseError.noJSONObject
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(stripped[open...close].utf8))
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
        return VisualSummary(imageKind: kind.rawValue, description: response.description,
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
