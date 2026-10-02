@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Synchronization
import Testing

/// The requests `OllamaClient` sends and how it reads what comes back, over its own session, guard and all, to a stub
/// server (`StubOllamaServer`) in place of the network: the method, path and body of each of Ollama's endpoints
/// (https://github.com/ollama/ollama/blob/main/docs/api.md), an answer streamed in pieces, each way an answer can fail,
/// and the bounds on time and size.
@Suite struct OllamaClientTests {
    /// A client of `server`, with the bundled settings changed by `change`, on a clock whose deadlines never come unless
    /// a test says otherwise. The server describes every model as one it runs itself, so the client sends it requests
    /// (`RemoteModelTests` covers the others).
    private func client(_ server: StubOllamaServer, time: TestTime = TestTime(.blocks),
                        _ change: (inout OllamaConfig) -> Void = { _ in }) throws -> OllamaClient {
        server.reply(to: "/api/show", with: .json(Self.shownHere))
        var config = try PipelineConfig.bundledDefaults().ollama
        change(&config)
        return try OllamaClient(config: config, baseURL: server.baseURL, time: time, transport: [StubOllamaServer.Transport.self])
    }

    /// A line of a streamed answer, as Ollama writes it.
    private static func line(_ content: String, done: Bool = false) -> String {
        let text = JSON.string(["model": JSONValue.string("qwen3.5:9b"), "message": ["role": "assistant", "content": .string(content)],
                                "done": .bool(done)])
        return done ? String(text.dropLast()) + #","done_reason":"stop","eval_count":3}"# : text
    }

    /// How Ollama describes a model it runs itself.
    private static let shownHere = #"{"capabilities":["completion","thinking"],"details":{"parameter_size":"9B"}}"#

    private static let chatRequest = OllamaChatRequest(
        model: "qwen3.5:9b", messages: [.system("Read it."), .user("Fatura", images: ["aW1n"])], format: ["type": "object"],
        options: ["num_ctx": 8192], keepAlive: "10m", think: false, timeout: nil)

    @Test func everyEndpointIsAskedByItsMethodPathAndBodyAndItsAnswerRead() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/version", with: .json(#"{"version":"0.18.2"}"#))
        server.reply(to: "/api/tags", with: .json(#"{"models":[{"name":"bge-m3:latest","model":"bge-m3:latest","size":1157672605}]}"#))
        server.reply(to: "/api/embed", with: .json(#"{"model":"bge-m3","embeddings":[[0.5,-0.25]]}"#))
        server.reply(to: "/api/chat", with: .json(Self.line(#"{"types":[]}"#, done: true)))
        server.reply(to: "/api/pull", with: .lines([#"{"status":"pulling","total":4,"completed":1}"#, #"{"status":"success"}"#], piecesOf: 7))
        let client = try client(server)

        #expect(try await client.version() == "0.18.2", "the version")
        #expect(try await client.tags().map(\.name) == ["bge-m3:latest"], "the installed models")
        #expect(try await client.show(model: "qwen3.5:9b").capabilities == ["completion", "thinking"], "what a model can do")
        let embedded = try await client.embed(OllamaEmbedRequest(model: "bge-m3", input: ["Fatura"], keepAlive: "30m", truncate: true,
                                                                 options: ["num_ctx": 8192]))
        #expect(embedded.embeddings == [[0.5, -0.25]], "a vector per input")
        let answer = try await client.chat(Self.chatRequest)
        #expect(answer.message.content == #"{"types":[]}"# && answer.done == true, "the whole answer")
        var progress: [String?] = []
        for try await step in client.pull(model: "bge-m3") { progress.append(step.status) }
        #expect(progress == ["pulling", "success"], "a download's progress, line by line")

        let sent = server.requests
        #expect(sent.map { "\($0.method) \($0.path)" } == ["GET /api/version", "GET /api/tags", "POST /api/show", "POST /api/show",
                                                           "POST /api/embed", "POST /api/chat", "POST /api/pull"],
                "each endpoint by its method and path; a model is described before it is first sent a request, once")
        #expect(sent[0].body.isEmpty && sent[1].body.isEmpty, "a GET carries no body")
        #expect(try sent[2].json() as NSDictionary == ["model": "qwen3.5:9b"] && sent[3].json() as NSDictionary == ["model": "bge-m3"],
                "show names the model")
        let embed = try sent[4].json()
        #expect(Set(embed.keys) == ["model", "input", "keep_alive", "truncate", "options"]
                    && embed["input"] as? [String] == ["Fatura"] && embed["truncate"] as? Bool == true && embed["keep_alive"] as? String == "30m",
                "embed sends its inputs, how long to keep the model, to truncate, and its options, in snake_case")
        let chat = try sent[5].json()
        #expect(Set(chat.keys) == ["model", "messages", "stream", "options", "format", "keep_alive", "think"],
                "chat sends the model, the messages, whether to stream, the options, the format, keep_alive and think")
        #expect(chat["stream"] as? Bool == false && chat["think"] as? Bool == false && chat["keep_alive"] as? String == "10m"
                    && (chat["options"] as? [String: Any])?["num_ctx"] as? Int == 8192 && (chat["format"] as? [String: String]) == ["type": "object"],
                "as the request has them, not streamed when no one waits for its words")
        let messages = try #require(chat["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"] && messages[1]["images"] as? [String] == ["aW1n"]
                    && messages[1]["content"] as? String == "Fatura", "each message with its role, its words and its images")
        #expect(try sent[6].json() as NSDictionary == ["model": "bge-m3", "stream": true], "a download is streamed")
    }

    /// A model's words may hold U+0085, U+2028 and U+2029, which Ollama's JSON writes as they are and which the
    /// platform's line sequence also ends a line at: an answer is framed on the line feed alone, so no object is cut.
    @Test func linesAreFramedOnTheLineFeedAlone() async throws {
        let words = "a\u{85}b\u{2028}c\u{2029}d\re"
        let text = Self.line(words) + "\n" + Self.line("!", done: true) + "\n"
        let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
            for byte in text.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        var framed: [Data] = []
        for try await line in OllamaLines(bytes, endpoint: .chat, lineLimit: 4096, totalLimit: 4096) { framed.append(line) }
        #expect(try framed.map { try OllamaClient.chatChunk($0, model: "m").message.content } == [words, "!"],
                "framed on the line feed, each object is whole, with the words as they were written")
    }

    @Test func aStreamedAnswerIsReadWholeHoweverItsPiecesFall() async throws {
        let server = try StubOllamaServer()
        // Pieces of 3 bytes end inside lines and inside the two bytes of "é" and the three of U+2028.
        let pieces = ["Fatura ", "de é", "nergia\u{2028}", "e água\u{85}"]
        server.reply(to: "/api/chat", with: .lines(pieces.map { Self.line($0) } + [Self.line("", done: true)], piecesOf: 3))
        let client = try client(server)
        let seen = Mutex<[String]>([])
        let answer = try await client.chat(Self.chatRequest) { sofar in seen.withLock { $0.append(sofar.message.content) } }
        let whole = pieces.joined()
        #expect(answer.message.content == whole && answer.done == true && answer.doneReason == "stop", "the whole answer, as written")
        #expect(seen.withLock { $0 } == (1...pieces.count).map { pieces.prefix($0).joined() } + [whole],
                "and the answer so far after each line, every character whole")
        #expect(try server.requests.last?.json()["stream"] as? Bool == true, "asked to stream, as someone waits for its words")
    }

    @Test func aStreamThatReportsAnErrorOrStopsShortIsNoAnswer() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/chat", with: .lines([Self.line("Fat"), #"{"error":"model runner has unexpectedly stopped"}"#], piecesOf: 16))
        let client = try client(server)
        await #expect(throws: OllamaError.answerFailed(model: "qwen3.5:9b", message: "model runner has unexpectedly stopped"),
                      "an error line ends the answer with it") {
            try await client.chat(Self.chatRequest) { _ in }
        }
        server.reply(to: "/api/chat", with: .lines([Self.line("Fat"), Self.line("ura")], piecesOf: 16))
        await #expect(throws: OllamaError.emptyResponse, "an answer that ends before its last line is no answer") {
            try await client.chat(Self.chatRequest) { _ in }
        }
    }

    @Test func eachFailingStatusIsTheErrorThePipelineActsOn() async throws {
        let server = try StubOllamaServer()
        let client = try client(server)
        server.reply(to: "/api/chat", with: .json(#"{"error":"model 'qwen3.5:9b' not found"}"#, status: 404))
        await #expect(throws: OllamaError.modelNotFound("qwen3.5:9b"), "a model Ollama does not have, answered whole") {
            try await client.chat(Self.chatRequest)
        }
        await #expect(throws: OllamaError.modelNotFound("qwen3.5:9b"), "or streamed") { try await client.chat(Self.chatRequest) { _ in } }
        server.reply(to: "/api/embed", with: .json(#"{"error":"busy"}"#, status: 503))
        await #expect(throws: OllamaError.http(status: 503, body: #"{"error":"busy"}"#), "a server error, which is retried") {
            try await client.embed(OllamaEmbedRequest(model: "bge-m3", input: ["x"], keepAlive: nil, truncate: true, options: nil))
        }
        server.reply(to: "/api/tags", with: .json("not json"))
        await #expect(throws: OllamaError.self, "an answer that is not what the API says") { try await client.tags() }
    }

    /// A redirect could send the request, and the document it carries, to any host; the session follows none.
    @Test func aRedirectIsRefusedAndNothingIsSentWhereItPoints() async throws {
        let server = try StubOllamaServer()
        let elsewhere = "http://elsewhere-\(UUID().uuidString.lowercased()).example/api/chat"
        server.reply(to: "/api/chat", with: .redirect(status: 307, location: elsewhere))
        server.reply(to: "/api/tags", with: .redirect(status: 301, location: elsewhere))
        let client = try client(server)
        await #expect(throws: OllamaError.redirected(endpoint: "api/chat", location: elsewhere), "a reply is refused") {
            try await client.chat(Self.chatRequest)
        }
        await #expect(throws: OllamaError.redirected(endpoint: "api/chat", location: elsewhere), "so is a streamed answer") {
            try await client.chat(Self.chatRequest) { _ in }
        }
        await #expect(throws: OllamaError.redirected(endpoint: "api/tags", location: elsewhere), "and any other endpoint") {
            try await client.tags()
        }
        #expect(server.requests.map(\.path) == ["/api/show", "/api/chat", "/api/chat", "/api/tags"], "each was sent once, to the server alone")
        #expect(!NetworkGuardProtocol.violations.contains { $0.hasPrefix(elsewhere) }, "and nothing was even tried where the redirect points")
        #expect(!(OllamaError.redirected(endpoint: "api/chat", location: elsewhere)).isTransient, "nor is it asked again")
    }

    /// The server never answers, so a cancellation that did not reach the request would leave the test waiting: it is
    /// bounded.
    @Test(.timeLimit(.minutes(1))) func cancellingTheTaskCancelsTheRequest() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/chat", with: .stall)
        let client = try client(server)
        for streamed in [false, true] {
            let before = server.stopped
            let asked = server.requests.filter { $0.path == "/api/chat" }.count
            let asking = Task { try await streamed ? client.chat(Self.chatRequest) { _ in } : client.chat(Self.chatRequest) }
            #expect(await Patience.until { server.requests.filter { $0.path == "/api/chat" }.count == asked + 1 }, "the request reached the server")
            asking.cancel()
            await #expect(throws: CancellationError.self, "the caller is told it was cancelled, not that it failed") { try await asking.value }
            #expect(await Patience.until { server.stopped == before + 1 }, "and the request itself is stopped, streamed: \(streamed)")
        }
    }

    @Test func anAnswerLargerThanTheLimitIsRefused() async throws {
        let server = try StubOllamaServer()
        let limit = 128
        let client = try client(server) { $0.maxResponseBytes = limit }
        server.reply(to: "/api/tags", with: .json(#"{"models":[{"name":"\#(String(repeating: "m", count: limit))"}]}"#))
        await #expect(throws: OllamaError.responseTooLarge(endpoint: "api/tags", limit: limit), "a reply") { try await client.tags() }
        let lines = (0..<4).map { _ in Self.line("ok") }
        try #require(lines.allSatisfy { $0.utf8.count < limit } && lines.joined().utf8.count > limit, "short lines, long together")
        server.reply(to: "/api/chat", with: .lines(lines, piecesOf: 10))
        await #expect(throws: OllamaError.responseTooLarge(endpoint: "api/chat", limit: limit), "every line of a streamed answer together") {
            try await client.chat(Self.chatRequest) { _ in }
        }
        server.reply(to: "/api/pull", with: .lines([#"{"status":"\#(String(repeating: "p", count: limit))"}"#], piecesOf: 10))
        await #expect(throws: OllamaError.responseTooLarge(endpoint: "api/pull", limit: limit), "a line of a download's progress") {
            for try await _ in client.pull(model: "bge-m3") {}
        }
        server.reply(to: "/api/pull", with: .lines(Array(repeating: #"{"status":"pulling"}"#, count: 8), piecesOf: 10))
        var steps = 0
        for try await _ in client.pull(model: "bge-m3") { steps += 1 }
        #expect(steps == 8, "while a download's lines together may hold more, as it streams for as long as it takes")
    }

    /// 0 is no timeout: neither for how long a request may wait for more of its answer, which URLSession would otherwise
    /// end after 60 seconds, nor for the whole of it.
    @Test func aTimeoutOfZeroIsNoTimeout() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/version", with: .json(#"{"version":"0.18.2"}"#))
        server.reply(to: "/api/chat", with: .json(Self.line("ok", done: true)))
        // Every sleep on this clock ends at once: a deadline armed for any of these would expire before the answer came.
        let unbounded = try client(server, time: TestTime(.advances)) { $0.timeouts = .init(meta: 0, version: 0, chat: 0, embed: 0, pull: 0) }
        let version = try await unbounded.version()
        let answer = try await unbounded.chat(Self.chatRequest)
        #expect(version == "0.18.2" && answer.done == true, "no deadline cuts a request that has none")
        #expect(server.requests.map(\.timeout) == [.infinity, .infinity, .infinity],
                "and none may wait for ever for more of its answer, the description of the model before the answer among them")
        let bounded = try client(server) { $0.timeouts.version = 1.5 }
        _ = try await bounded.version()
        #expect(server.requests.last?.timeout == 1.5, "a timeout set is the time a request may wait for more")
    }
}
