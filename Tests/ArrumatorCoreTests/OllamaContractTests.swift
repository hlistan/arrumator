@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
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
        #expect(!answer.reachedLengthLimit, "an answer that stopped by itself is complete")
        let cut = try decode(OllamaChatResponse.self, """
            {"model":"qwen3.5:9b","message":{"role":"assistant","content":"","thinking":"First, the request asks for"},
             "done":true,"done_reason":"length","eval_count":8192}
            """)
        #expect(cut.reachedLengthLimit && cut.message.content.isEmpty,
                "a model that thought until num_predict ran out stops at its length limit, before writing the answer")
    }

    @Test func anEmbeddingAndTheInstalledModelsDecode() throws {
        let embedded = try decode(OllamaEmbedResponse.self, """
            {"model":"bge-m3","embeddings":[[0.010071029,-0.0017594862,0.05007221]],"total_duration":14143917,
             "load_duration":1019500,"prompt_eval_count":8}
            """)
        #expect(embedded.embeddings == [[0.010071029, -0.0017594862, 0.05007221]], "one vector per input")
        let tags = try decode([String: [OllamaModelInfo]].self, """
            {"models":[{"name":"bge-m3:latest","model":"bge-m3:latest","modified_at":"2026-05-10T08:06:48-07:00","size":1157672605,
              "digest":"790764642607","details":{"family":"bert","parameter_size":"566.70M","quantization_level":"F16"}}]}
            """)
        #expect(tags["models"]?.map(\.name) == ["bge-m3:latest"] && tags["models"]?.first?.size == 1_157_672_605,
                "installed models are found by name, with their size")
    }

    // MARK: Thinking (https://docs.ollama.com/capabilities/thinking)

    @Test func aModelSaysHowItThinksAsSwitchesAsLevelsOrNotAtAll() throws {
        let levels = try decode(OllamaShowResponse.self, """
            {"modelfile":"FROM x","details":{"format":"gguf","family":"gptoss","parameter_size":"20.9B","quantization_level":"MXFP4"},
             "capabilities":["completion","tools","thinking"],"thinking":{"values":["low","medium","high"],"default":"medium"}}
            """)
        #expect(levels.thinking == .levels && levels.details?.parameterSize == "20.9B",
                "gpt-oss names the levels it thinks at, and the one it thinks at when not told")
        let switches = try decode(OllamaShowResponse.self, """
            {"capabilities":["completion","tools","thinking"],"thinking":{"values":[true,false],"default":true}}
            """)
        #expect(switches.thinking == .switches, "a model that thinks or not as it is switched lists the two switches")
        let never = try decode(OllamaShowResponse.self, #"{"capabilities":["completion","vision"],"thinking":{"values":[false]}}"#)
        #expect(never.thinking == .never, "a model that cannot think says so with the one switch, off")
        let older = try decode(OllamaShowResponse.self, """
            {"modelfile":"FROM x","details":{"format":"gguf","family":"mistral","parameter_size":"14B","quantization_level":"Q4_K_M"},
             "model_info":{"general.architecture":"mistral3"},"capabilities":["completion","vision","thinking"]}
            """)
        #expect(older.thinking == nil && older.capabilities?.contains(OllamaShowResponse.thinkingCapability) == true,
                "an older server, or a model without the metadata, says only that the model can think, by its capability")
        // What the app cannot act on in the optional `thinking` object leaves the rest of the answer standing.
        let unreadable = [
            (#"{"values":[1],"default":true}"#, "a value that is neither a switch nor a level's name"),
            (#"{"values":["low",""]}"#, "a level without a name, which would tell a model nothing"),
            (#""yes""#, "a thinking that is no object"),
        ]
        for (thinking, what) in unreadable {
            let shown = try decode(OllamaShowResponse.self, """
                {"details":{"parameter_size":"9B"},"capabilities":["completion","vision","thinking"],"thinking":\(thinking)}
                """)
            #expect(shown.thinking == nil && shown.thinkingProblem != nil,
                    "\(what) is read as no thinking metadata, and why is kept to be logged with the model's name")
            #expect(shown.capabilities == ["completion", "vision", "thinking"] && shown.details?.parameterSize == "9B",
                    "\(what): the rest of the answer is read, so the model is still listed and offered for its roles")
            #expect(shown.thinkingValues == [.on, .off], "\(what): its capability decides how it is told to think, as on an older server")
        }
        #expect(levels.thinkingProblem == nil && older.thinkingProblem == nil, "metadata that reads, or none at all, is no problem")
        #expect(throws: DecodingError.self, "a level without a name is still refused where the app's own configuration asks for one") {
            try JSON.decoder.decode(OllamaThink.self, from: Data(#""""#.utf8))
        }
    }

    @Test func thinkIsSentAsASwitchOrALevelAndLeftOutWhenUnset() throws {
        func body(_ think: OllamaThink?) -> String { OllamaChatRequest.sample(think: think).body.serialized() }
        #expect(body(false).contains(#""think":false"#), "a model is switched off as Ollama takes it, with false")
        #expect(body(true).contains(#""think":true"#), "and on with true")
        #expect(body("high").contains(#""think":"high""#), "a level goes by its name")
        #expect(!body(nil).contains(#""think""#), "nothing to send leaves the key out, so the model thinks as it does by default")
        #expect(try JSON.string([false, true, "high"] as [OllamaThink]) == #"[false,true,"high"]"#,
                "a trace records what was sent as the request carried it")
    }

    @Test func aModelIsSentOnlyAThinkingValueItListsElseItsDefaultStands() {
        let thinks = MockOllama.thinkingCapabilities
        let cannot = MockOllama.shown(capabilities: ["completion"], thinking: nil)
        #expect(cannot.think(sending: true) == nil, "a model that cannot think is not told to")
        #expect(cannot.think(sending: false) == nil, "nor told not to")
        #expect(MockOllama.shown(capabilities: thinks, thinking: .never).think(sending: true) == nil,
                "a model that lists only off cannot think, whatever its capabilities say")
        let older = MockOllama.shown(capabilities: thinks, thinking: nil)
        #expect(older.think(sending: false) == false, "a model that lists nothing but can think is switched off as asked")
        #expect(older.think(sending: true) == true, "and on")
        #expect(older.think(sending: "high") == true, "and a level is sent as on, which every such model takes")
        let unlisted = OllamaShowResponse.Thinking(values: nil, default: nil)
        #expect(MockOllama.shown(capabilities: thinks, thinking: unlisted).think(sending: "high") == true,
                "a thinking object that lists no values leaves it to the capability")
        let empty = OllamaShowResponse.Thinking(values: [], default: nil)
        #expect(MockOllama.shown(capabilities: thinks, thinking: empty).think(sending: true) == true,
                "and so does an empty list, which Ollama leaves out")
        let switches = MockOllama.shown(capabilities: thinks, thinking: .switches)
        #expect(switches.think(sending: false) == false, "a model that lists the switches is switched off as asked")
        #expect(switches.think(sending: true) == true, "and on")
        #expect(switches.think(sending: "high") == true, "and a level it does not name is sent as on, which it lists")
        let levels = MockOllama.shown(capabilities: thinks, thinking: .levels)
        #expect(levels.think(sending: "high") == "high", "a model that names levels is sent the one wanted")
        #expect(levels.think(sending: "max") == nil, "a level it does not name is not sent, so it thinks at its default")
        #expect(levels.think(sending: true) == nil, "nor is on, which it does not list")
        #expect(levels.think(sending: false) == nil, "nor off, which it does not list: it cannot stop thinking")
        #expect(MockOllama.shown(capabilities: ["completion"], thinking: .levels).think(sending: "low") == "low",
                "the levels a model names say it can think even when its capabilities do not")
        let always = OllamaShowResponse.Thinking(values: [true], default: true)
        #expect(MockOllama.shown(capabilities: thinks, thinking: always).think(sending: false) == nil,
                "a model that lists only on is not told off, which it cannot do")
    }

    /// A streamed answer comes a line at a time (https://github.com/ollama/ollama/blob/main/docs/api.md#generate-a-chat-completion):
    /// the words and thinking each line adds, and on the last line why it ended and the counters.
    @Test func aStreamedAnswerAddsUpLineByLineAndEndsOnTheErrorItStreams() throws {
        let lines = [
            #"{"model":"qwen3.5:9b","created_at":"2026-07-05T12:00:00Z","message":{"role":"assistant","content":"","thinking":"Sum "},"done":false}"#,
            #"{"model":"qwen3.5:9b","created_at":"2026-07-05T12:00:01Z","message":{"role":"assistant","content":"","thinking":"them."},"done":false}"#,
            #"{"model":"qwen3.5:9b","created_at":"2026-07-05T12:00:02Z","message":{"role":"assistant","content":"{\"answer\": \"72"},"done":false}"#,
            #"{"model":"qwen3.5:9b","created_at":"2026-07-05T12:00:03Z","message":{"role":"assistant","content":",61\"}"},"done":true,"#
                + #""done_reason":"stop","total_duration":5191566416,"prompt_eval_count":26,"eval_count":298}"#,
        ]
        var sofar: [OllamaChatResponse] = []
        for line in lines {
            let chunk = try OllamaClient.chatChunk(Data(line.utf8), model: "qwen3.5:9b")
            sofar.append(sofar.last.map { $0.continued(by: chunk) } ?? chunk)
        }
        #expect(sofar[1].message.thinking == "Sum them." && sofar[1].message.content.isEmpty && sofar[1].done == false,
                "thinking adds up before the answer is written")
        let whole = try #require(sofar.last)
        #expect(whole.message.content == #"{"answer": "72,61"}"# && whole.message.thinking == "Sum them.", "then the answer's words")
        #expect(whole.done == true && whole.doneReason == "stop" && whole.metrics.promptTokens == 26 && whole.metrics.outputTokens == 298,
                "and the last line ends it with its counters, which reach the trace")
        #expect(throws: OllamaError.answerFailed(model: "qwen3.5:9b", message: "model runner has unexpectedly stopped"),
                "an error line ends the answer with it, named as such") {
            try OllamaClient.chatChunk(Data(#"{"error":"model runner has unexpectedly stopped"}"#.utf8), model: "qwen3.5:9b")
        }
        #expect(!OllamaError.answerFailed(model: "x", message: "y").isTransient, "and it is not asked again behind the user's back")
        #expect(throws: OllamaError.self, "a line that is no answer is no answer") { try OllamaClient.chatChunk(Data("not json".utf8), model: "m") }
        var streamed = OllamaChatRequest.sample(think: nil)
        streamed.stream = true
        #expect(streamed.body.serialized().contains(#""stream":true"#), "a request streamed says so")
    }

    @Test func theGateStreamsTheAnswerAsItGrowsAndAgainFromItsStartWhenItIsAskedAgain() async throws {
        let away = Mutex(true)
        let mock = MockOllama { _ in
            // The server is away the first time it is asked, and answers the next.
            if away.withLock({ wasAway in defer { wasAway = false }; return wasAway }) { throw OllamaError.unreachable("not yet") }
            return "Duas faturas somam 72 EUR"
        }
        let gate = InferenceGate(api: mock, retryDelays: [1], time: TestTime(.advances))
        let seen = Mutex<[String]>([])
        let whole = try await gate.chat(.sample(think: nil)) { sofar in seen.withLock { $0.append(sofar.message.content) } }
        #expect(whole.message.content == "Duas faturas somam 72 EUR" && whole.done == true, "the whole answer comes back")
        #expect(seen.withLock { $0 } == ["Duas ", "Duas faturas ", "Duas faturas somam ", "Duas faturas somam 72 ", "Duas faturas somam 72 EUR"],
                "each time it grew, the answer so far was given")
        #expect(await mock.chatCount == 2, "after the server came back, asked again from its start")
    }

    /// A server that cannot be reached, whatever is asked of it.
    struct AwayServer: OllamaAPI {
        var baseURL: URL { MockOllama.server }
        func version() async throws -> String { throw OllamaError.unreachable("Could not connect to the server.") }
        func tags() async throws -> [OllamaModelInfo] { throw OllamaError.unreachable("down") }
        func show(model: String) async throws -> OllamaShowResponse { throw OllamaError.unreachable("down") }
        func chat(_ request: OllamaChatRequest, partial: (@Sendable (OllamaChatResponse) async -> Void)?) async throws -> OllamaChatResponse {
            throw OllamaError.unreachable("down")
        }
        func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse { throw OllamaError.unreachable("down") }
        func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> { AsyncThrowingStream { $0.finish() } }
    }

    @Test func aServerOnAnotherMachineThatCannotBeReachedIsSaidToBeUnreachableNotStopped() async throws {
        let config = try PipelineConfig.bundledDefaults().ollama
        let address = try #require(URL(string: "http://192.168.1.254:11434"))
        let lifecycle = OllamaLifecycle(api: AwayServer(), config: config, management: .external, binaryOverride: nil, address: address,
                                        time: TestTime(.advances))
        let state = await lifecycle.check()
        #expect(state == .unreachable("192.168.1.254"), "nothing is known of whether it runs there, only that it cannot be reached")
        #expect(state.summary == "Ollama at 192.168.1.254 cannot be reached", "and that is what the app says")
    }

    /// A server whose every request a stop cuts off, as `OllamaClient` throws for it.
    struct CutOffServer: OllamaAPI {
        var baseURL: URL { MockOllama.server }
        func version() async throws -> String { throw CancellationError() }
        func tags() async throws -> [OllamaModelInfo] { throw CancellationError() }
        func show(model: String) async throws -> OllamaShowResponse { throw CancellationError() }
        func chat(_ request: OllamaChatRequest, partial: (@Sendable (OllamaChatResponse) async -> Void)?) async throws -> OllamaChatResponse {
            throw CancellationError()
        }
        func embed(_ request: OllamaEmbedRequest) async throws -> OllamaEmbedResponse { throw CancellationError() }
        func pull(model: String) -> AsyncThrowingStream<OllamaPullProgress, any Error> { AsyncThrowingStream { $0.finish() } }
    }

    @Test func aCheckAStopCutsOffLearnsNothingOfTheServer() async throws {
        let config = try PipelineConfig.bundledDefaults().ollama
        let address = try #require(URL(string: "http://127.0.0.1:11434"))
        let lifecycle = OllamaLifecycle(api: CutOffServer(), config: config, management: .external, binaryOverride: nil, address: address,
                                        time: TestTime(.advances))
        let before = await lifecycle.state
        #expect(await lifecycle.check() == before && before == .unknown,
                "a request the stop cut off says nothing of whether Ollama runs, so it is not said to be stopped, which would start it")
    }

    @Test func aDownloadReportsProgressAndEndsOnTheErrorItStreams() throws {
        let pulling = try OllamaClient.progress(Data(#"{"status":"pulling 6a0746a1ec1a","digest":"6a0746a1ec1a","total":4000,"completed":1000}"#.utf8),
                                                model: "bge-m3")
        #expect(pulling.fraction == 0.25, "Settings shows how far the download is")
        #expect(throws: OllamaError.pullFailed(model: "bge-m3", message: "pull model manifest: file does not exist"),
                "an error line is a failed download, named as such, not a server error to retry") {
            try OllamaClient.progress(Data(#"{"error":"pull model manifest: file does not exist"}"#.utf8), model: "bge-m3")
        }
        #expect(!OllamaError.pullFailed(model: "x", message: "y").isTransient, "a failed download is not retried behind the user's back")
    }

    @Test func everyFailureBecomesTheErrorThePipelineActsOn() throws {
        #expect(OllamaClient.failure(try response(200), body: "{}", endpoint: .chat, model: "m") == nil, "success is no failure")
        #expect(OllamaClient.failure(try response(404), body: #"{"error":"model 'm' not found"}"#, endpoint: .chat, model: "m") == .modelNotFound("m"),
                "a model Ollama does not have holds the document until it is downloaded")
        let busy = OllamaClient.failure(try response(503), body: "busy", endpoint: .chat, model: "m")
        #expect(busy == .http(status: 503, body: "busy") && busy?.isTransient == true, "a server error is retried with backoff")
        let bad = OllamaClient.failure(try response(400), body: "bad", endpoint: .chat, model: "m")
        #expect(bad == .http(status: 400, body: "bad") && bad?.isTransient == false, "a bad request is not")
        #expect(OllamaClient.map(URLError(.timedOut)) as? OllamaError == .timeout("request"), "a timeout keeps the document waiting")
        #expect(OllamaClient.map(URLError(.cannotConnectToHost)) as? OllamaError
                    == .unreachable(URLError(.cannotConnectToHost).localizedDescription), "so does a server that is not running")
        #expect(OllamaClient.map(URLError(.cancelled)) is CancellationError, "and stopping the app is no failure at all")
    }

    /// A search task's effort gives its request a time of its own (`OllamaChatRequest.timeout`); an answer that takes
    /// longer would take as long again, holding the one model that generates all the while.
    @Test func aRequestThatOutlastsItsOwnTimeoutIsNotAskedAgainWhileOneWithoutIs() async throws {
        let delays = try PipelineConfig.bundledDefaults().ollama.retryDelays
        try #require(!delays.isEmpty, "the bundled configuration asks again after a transient failure")
        let timedOut = OllamaError.timeout("/api/chat")
        var own = OllamaChatRequest.sample(think: nil)
        own.timeout = 900
        let slow = MockOllama { _ in throw timedOut }
        let gate = InferenceGate(api: slow, retryDelays: delays, time: TestTime(.advances))
        await #expect(throws: timedOut, "the timeout reaches the caller") { try await gate.chat(own) }
        #expect(await slow.chatCount == 1, "a request that took longer than its own timeout is asked once, and the model is free again")
        await #expect(throws: timedOut, "one without a timeout of its own") { try await gate.chat(.sample(think: nil)) }
        #expect(await slow.chatCount == 2 + delays.count, "is asked again after each of ollama.retryDelays, as a server slow for a while may answer")
        let away = MockOllama { _ in throw OllamaError.unreachable("connection refused") }
        let waiting = InferenceGate(api: away, retryDelays: delays, time: TestTime(.advances))
        await #expect(throws: OllamaError.self, "a server that cannot be reached") { try await waiting.chat(own) }
        #expect(await away.chatCount == 1 + delays.count, "is asked again whatever time the request has of its own")
        #expect(!timedOut.isTransient(asking: own) && timedOut.isTransient(asking: .sample(think: nil))
                    && OllamaError.unreachable("x").isTransient(asking: own), "which is what decides it, for the gate and the caller alike")
    }
}
