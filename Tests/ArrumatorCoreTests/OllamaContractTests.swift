@testable import ArrumatorCore
import Foundation
import Testing

/// The contract with Ollama's HTTP API (https://github.com/ollama/ollama/blob/main/docs/api.md): the answers it gives,
/// as its documentation shows them, decode into the app's types, and every failure it can report becomes the error the
/// pipeline acts on. `MockOllama` stands in for the server everywhere else, so this is where its wire format is checked.
@Suite struct OllamaContractTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try OllamaClient.decoder.decode(type, from: Data(json.utf8))
    }

    private func response(_ status: Int) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "http://127.0.0.1:11434/api/chat"))
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }

    @Test func aChatAnswerDecodesWithItsCounters() throws {
        let answer = try decode(OllamaChatResponse.self, """
            {"model":"ministral-3:14b","created_at":"2026-07-05T12:00:00Z","message":{"role":"assistant","content":"{\\"types\\":[]}"},
             "done":true,"done_reason":"stop","total_duration":5191566416,"load_duration":2154458,"prompt_eval_count":26,
             "prompt_eval_duration":383809000,"eval_count":298,"eval_duration":4799921000}
            """)
        #expect(answer.message == .assistant(#"{"types":[]}"#), "the answer's text is what the validator reads")
        #expect(answer.metrics.promptTokens == 26 && answer.metrics.outputTokens == 298, "token counts reach the trace")
        #expect(answer.metrics.totalMs == 5191.566416, "durations come in nanoseconds and are recorded in milliseconds")
    }

    @Test func embeddingsCapabilitiesAndInstalledModelsDecode() throws {
        let embedded = try decode(OllamaEmbedResponse.self, """
            {"model":"bge-m3","embeddings":[[0.010071029,-0.0017594862,0.05007221]],"total_duration":14143917,
             "load_duration":1019500,"prompt_eval_count":8}
            """)
        #expect(embedded.embeddings == [[0.010071029, -0.0017594862, 0.05007221]], "one vector per input")
        let shown = try decode(OllamaShowResponse.self, """
            {"modelfile":"FROM x","details":{"format":"gguf","family":"mistral","parameter_size":"14B","quantization_level":"Q4_K_M"},
             "model_info":{"general.architecture":"mistral3"},"capabilities":["completion","vision","thinking"]}
            """)
        #expect(shown.supportsThinking && shown.details?.parameterSize == "14B", "a thinking model is asked not to think aloud")
        let tags = try decode([String: [OllamaModelInfo]].self, """
            {"models":[{"name":"bge-m3:latest","model":"bge-m3:latest","modified_at":"2026-05-10T08:06:48-07:00","size":1157672605,
              "digest":"790764642607","details":{"family":"bert","parameter_size":"566.70M","quantization_level":"F16"}}]}
            """)
        #expect(tags["models"]?.map(\.name) == ["bge-m3:latest"] && tags["models"]?.first?.size == 1_157_672_605,
                "installed models are found by name, with their size")
    }

    @Test func aDownloadReportsProgressAndEndsOnTheErrorItStreams() throws {
        let pulling = try OllamaClient.progress(#"{"status":"pulling 6a0746a1ec1a","digest":"6a0746a1ec1a","total":4000,"completed":1000}"#,
                                                model: "bge-m3")
        #expect(pulling.fraction == 0.25, "Settings shows how far the download is")
        #expect(throws: OllamaError.pullFailed(model: "bge-m3", message: "pull model manifest: file does not exist"),
                "an error line is a failed download, named as such, not a server error to retry") {
            try OllamaClient.progress(#"{"error":"pull model manifest: file does not exist"}"#, model: "bge-m3")
        }
        #expect(!OllamaError.pullFailed(model: "x", message: "y").isTransient, "a failed download is not retried behind the user's back")
    }

    @Test func everyFailureBecomesTheErrorThePipelineActsOn() throws {
        #expect(OllamaClient.failure(try response(200), body: "{}", model: "m") == nil, "success is no failure")
        #expect(OllamaClient.failure(try response(404), body: #"{"error":"model 'm' not found"}"#, model: "m") == .modelNotFound("m"),
                "a model Ollama does not have holds the document until it is downloaded")
        let busy = OllamaClient.failure(try response(503), body: "busy", model: "m")
        #expect(busy == .http(status: 503, body: "busy") && busy?.isTransient == true, "a server error is retried with backoff")
        let bad = OllamaClient.failure(try response(400), body: "bad", model: "m")
        #expect(bad == .http(status: 400, body: "bad") && bad?.isTransient == false, "a bad request is not")
        #expect(OllamaClient.map(URLError(.timedOut)) as? OllamaError == .timeout("request"), "a timeout keeps the document waiting")
        #expect(OllamaClient.map(URLError(.cannotConnectToHost)) as? OllamaError
                    == .unreachable(URLError(.cannotConnectToHost).localizedDescription), "so does a server that is not running")
        #expect(OllamaClient.map(URLError(.cancelled)) is CancellationError, "and stopping the app is no failure at all")
    }
}
