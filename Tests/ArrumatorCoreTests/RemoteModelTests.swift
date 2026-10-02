@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// A model the Ollama server does not run itself, but sends requests for elsewhere, is never sent anything (AGENTS.md
/// §4.1); `ModelLocation` says how Ollama 0.18.2 does so. The client asks where a model runs before it sends one a
/// request, once for each model of its server, and sends nothing to a model whose place it cannot tell.
@Suite struct RemoteModelTests {
    static let cloud = "gpt-oss:120b-cloud"
    static let host = "https://ollama.com:443"
    static let local = "qwen3.5:9b"
    /// How Ollama describes a model it runs itself, and one it runs at `host`, as `ShowResponse` in api/types.go has it.
    static let shownHere = #"{"capabilities":["completion"],"details":{"parameter_size":"9B"}}"#
    static let shownElsewhere = #"{"remote_model":"gpt-oss:120b","remote_host":"https://ollama.com:443","capabilities":["completion"]}"#

    private func client(_ server: StubOllamaServer, time: TestTime = TestTime(.blocks)) throws -> OllamaClient {
        try OllamaClient(config: try PipelineConfig.bundledDefaults().ollama, baseURL: server.baseURL, time: time,
                         transport: [StubOllamaServer.Transport.self])
    }

    private static func chat(_ model: String, timeout: Double? = nil) -> OllamaChatRequest {
        var request = OllamaChatRequest.sample(think: nil)
        request.model = model
        request.timeout = timeout
        return request
    }

    private static func embed(_ model: String) -> OllamaEmbedRequest {
        OllamaEmbedRequest(model: model, input: ["Fatura"], keepAlive: nil, truncate: true, options: nil)
    }

    private static let answer = #"{"model":"qwen3.5:9b","message":{"role":"assistant","content":"Duas faturas"},"done":true}"#

    /// `/api/tags` and `/api/show` as Ollama 0.18.2 writes them for a cloud model pulled as a stub: the fields of
    /// `ListModelResponse` and `ShowResponse` in its api/types.go.
    @Test func ollamaListsAndDescribesAModelItRunsElsewhereWithWhere() throws {
        let tags = try OllamaClient.decoder.decode([String: [OllamaModelInfo]].self, from: Data("""
            {"models":[{"name":"gpt-oss:120b-cloud","model":"gpt-oss:120b-cloud","remote_model":"gpt-oss:120b",
              "remote_host":"https://ollama.com:443","modified_at":"2026-09-30T10:00:00Z","size":384,"digest":"9a8c",
              "details":{"format":"","family":"gptoss","parameter_size":"116.8B","quantization_level":"MXFP4"}},
             {"name":"qwen3.5:9b","model":"qwen3.5:9b","modified_at":"2026-09-30T10:00:00Z","size":6600000000,"digest":"1b2c",
              "details":{"format":"gguf","family":"qwen35","parameter_size":"9B","quantization_level":"Q4_K_M"}}]}
            """.utf8))
        let listed = try #require(tags["models"])
        #expect(listed.map(\.remoteHost) == [Self.host, nil] && listed.first?.remoteModel == "gpt-oss:120b",
                "the listing says which model runs elsewhere, and where; a model the server runs itself says nothing")
        let shown = try OllamaClient.decoder.decode(OllamaShowResponse.self, from: Data(Self.shownElsewhere.utf8))
        #expect(shown.remoteHost == Self.host && shown.remoteModel == "gpt-oss:120b", "and so does its description")
    }

    @Test func aNameThatAsksForOllamasCloudIsKnownByItsName() {
        for name in ["gpt-oss:120b-cloud", "gpt-oss:120b:cloud", "qwen3:CLOUD", "deepseek-v3.1:671b-cloud "] {
            #expect(ModelLocation.namesCloud(name), "\(name) is sent to Ollama's cloud whatever the server lists")
        }
        for name in ["qwen3.5:9b", "bge-m3", "cloud", "cloud:latest", "someone/cloud-model:latest", "registry.local/x/y:7b"] {
            #expect(!ModelLocation.namesCloud(name), "\(name) is not")
        }
    }

    @Test func aModelOllamaRunsElsewhereIsSentNothing() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/show", with: .json(Self.shownElsewhere))
        server.reply(to: "/api/chat", with: .json(Self.answer))
        let client = try client(server)
        for model in [Self.cloud, "gpt-oss:20b:cloud"] {
            await #expect(throws: OllamaError.runsElsewhere(model: model, host: ModelLocation.cloudPlace), "\(model), by its name") {
                try await client.chat(Self.chat(model))
            }
            await #expect(throws: OllamaError.runsElsewhere(model: model, host: ModelLocation.cloudPlace), "\(model) embeds nothing either") {
                try await client.embed(Self.embed(model))
            }
        }
        #expect(server.requests.isEmpty, "a name that asks for the cloud is refused before the server is asked anything")
        // Made from a cloud model (`ollama create mine --from gpt-oss:120b-cloud`): its name says nothing, Ollama does.
        let made = "mine:latest"
        await #expect(throws: OllamaError.runsElsewhere(model: made, host: Self.host), "a model Ollama describes as running elsewhere") {
            try await client.chat(Self.chat(made))
        }
        await #expect(throws: OllamaError.runsElsewhere(model: made, host: Self.host), "embeds nothing either") {
            try await client.embed(Self.embed(made))
        }
        await #expect(throws: OllamaError.runsElsewhere(model: made, host: Self.host), "nor answers streamed") {
            try await client.chat(Self.chat(made)) { _ in }
        }
        #expect(server.requests.map(\.path) == ["/api/show"], "it was asked where the model runs once, and sent nothing")
        #expect(!OllamaError.runsElsewhere(model: made, host: Self.host).isTransient, "and the refusal is not asked again")
    }

    /// The check and the request go to one client, so to one server; it is asked once for each model, and again once
    /// a download may have changed the model, or by a client for another address.
    @Test func whereAModelRunsIsAskedOncePerServerAndAgainAfterADownload() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/show", with: .json(Self.shownHere))
        server.reply(to: "/api/chat", with: .json(Self.answer))
        server.reply(to: "/api/pull", with: .lines([#"{"status":"success"}"#], piecesOf: 64))
        let client = try client(server)
        for _ in 0..<2 { _ = try await client.chat(Self.chat(Self.local)) }
        #expect(server.requests.map(\.path) == ["/api/show", "/api/chat", "/api/chat"], "asked where it runs once, then sent each request")
        for try await _ in client.pull(model: Self.local) {}
        server.reply(to: "/api/show", with: .json(Self.shownElsewhere))
        await #expect(throws: OllamaError.runsElsewhere(model: Self.local, host: Self.host), "after a download it is asked again") {
            try await client.chat(Self.chat(Self.local))
        }
        server.reply(to: "/api/show", with: .json(Self.shownHere))
        _ = try await self.client(server).chat(Self.chat(Self.local))
        #expect(server.requests.map(\.path).suffix(4) == ["/api/pull", "/api/show", "/api/show", "/api/chat"],
                "and a client for an address, as pointing the app at a server makes, asks for itself")
    }

    /// What the server said of where a model runs is trusted for `ollama.modelLocationMaxAge` seconds at most: a model
    /// remade on the server from a cloud model (`ollama create mine --from gpt-oss:120b-cloud`) is sent nothing once
    /// that age has passed.
    @Test func whatTheServerSaidOfAModelIsTrustedForALimitedTime() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/show", with: .json(Self.shownHere))
        server.reply(to: "/api/chat", with: .json(Self.answer))
        let time = TestTime(.blocks)
        var config = try PipelineConfig.bundledDefaults().ollama
        config.modelLocationMaxAge = 60
        let client = try OllamaClient(config: config, baseURL: server.baseURL, time: time, transport: [StubOllamaServer.Transport.self])
        _ = try await client.chat(Self.chat(Self.local))
        time.advance(by: 60)
        _ = try await client.chat(Self.chat(Self.local))
        #expect(server.requests.map(\.path) == ["/api/show", "/api/chat", "/api/chat"], "within the age, the answer stands")
        server.reply(to: "/api/show", with: .json(Self.shownElsewhere))
        time.advance(by: 1)
        await #expect(throws: OllamaError.runsElsewhere(model: Self.local, host: Self.host), "past it, the server is asked again") {
            try await client.chat(Self.chat(Self.local))
        }
        config.modelLocationMaxAge = 0
        let asking = try OllamaClient(config: config, baseURL: server.baseURL, time: time, transport: [StubOllamaServer.Transport.self])
        server.reply(to: "/api/show", with: .json(Self.shownHere))
        for _ in 0..<2 { _ = try await asking.chat(Self.chat(Self.local)) }
        #expect(server.requests.map(\.path).suffix(4) == ["/api/show", "/api/chat", "/api/show", "/api/chat"],
                "and an age of 0 asks before every request")
    }

    /// Whatever the app reads of the server, a listing (`/api/tags`, as Settings and the doctor read it) or a
    /// description, that says a model runs elsewhere, holds at once.
    @Test func aListingOrDescriptionThatSaysAModelRunsElsewhereHoldsAtOnce() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/show", with: .json(Self.shownHere))
        server.reply(to: "/api/chat", with: .json(Self.answer))
        let client = try client(server)
        _ = try await client.chat(Self.chat(Self.local))
        server.reply(to: "/api/tags", with: .json("""
            {"models":[{"name":"\(Self.local)","model":"\(Self.local)","remote_model":"gpt-oss:120b","remote_host":"\(Self.host)"}]}
            """))
        _ = try await client.tags()
        await #expect(throws: OllamaError.runsElsewhere(model: Self.local, host: Self.host), "a listing that says so") {
            try await client.chat(Self.chat(Self.local))
        }
        let other = "llama3.2:3b"
        _ = try await client.chat(Self.chat(other))
        server.reply(to: "/api/show", with: .json(Self.shownElsewhere))
        _ = try await client.show(model: other)
        await #expect(throws: OllamaError.runsElsewhere(model: other, host: Self.host), "a description that says so") {
            try await client.chat(Self.chat(other))
        }
        #expect(server.requests.map(\.path) == ["/api/show", "/api/chat", "/api/tags", "/api/show", "/api/chat", "/api/show"],
                "each refused at once, without asking again")
    }

    /// Without its place known a model is sent nothing: a server that is away or slow makes the request wait as Ollama
    /// being away does, even one with a timeout of its own; any other failure fails it; a model Ollama does not have is
    /// that, as its request would be answered.
    @Test func aModelWhosePlaceCannotBeToldIsSentNothing() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/chat", with: .json(Self.answer))
        let client = try client(server)
        server.reply(to: "/api/show", with: .json(#"{"error":"busy"}"#, status: 503))
        let away = OllamaError.locationUnknown(model: Self.local, because: .http(status: 503, body: #"{"error":"busy"}"#))
        await #expect(throws: away, "a server that cannot say now") { try await client.chat(Self.chat(Self.local)) }
        #expect(away.isTransient && away.isTransient(asking: Self.chat(Self.local, timeout: 900)), "waits, as for Ollama being away")
        server.reply(to: "/api/show", with: .json(#"{"error":"unexpected"}"#, status: 400))
        await #expect(throws: OllamaError.locationUnknown(model: Self.local, because: .http(status: 400, body: #"{"error":"unexpected"}"#)),
                      "a server that will not say fails the request") {
            try await client.embed(Self.embed(Self.local))
        }
        server.reply(to: "/api/show", with: .json(#"{"error":"model 'qwen3.5:9b' not found"}"#, status: 404))
        await #expect(throws: OllamaError.modelNotFound(Self.local), "a model it does not have is that") {
            try await client.chat(Self.chat(Self.local))
        }
        #expect(!server.requests.contains { $0.path == "/api/chat" || $0.path == "/api/embed" }, "and none of them was sent a request")
        server.reply(to: "/api/show", with: .json(Self.shownHere))
        _ = try await client.chat(Self.chat(Self.local))
        #expect(server.requests.last?.path == "/api/chat", "once it can tell, the request is sent: no failure was remembered")
    }

    /// A description that takes longer than `ollama.timeouts.meta` is a server slow for now, not an answer that took
    /// longer than its request's own timeout, which would fail a task for good.
    @Test func aSlowDescriptionMakesTheRequestWaitNotFail() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/show", with: .stall)
        let client = try client(server, time: TestTime(.advances))
        let own = Self.chat(Self.local, timeout: 900)
        do {
            _ = try await client.chat(own)
            Issue.record("a request whose model's place is not known is not sent")
        } catch let error as OllamaError {
            guard case let .locationUnknown(model, because) = error, case .timeout = because else {
                Issue.record("the description timed out: \(error)")
                return
            }
            #expect(model == Self.local && error.isTransient(asking: own), "it waits, as for Ollama being away, and is asked again")
        }
        #expect(!server.requests.contains { $0.path == "/api/chat" }, "and nothing was sent")
    }

    @Test func theModelsSayWhichRunElsewhereAndAProfileCanGiveThoseNothing() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let mock = MockOllama(installed: [Self.cloud, Self.local], remoteHosts: [Self.cloud: Self.host]) { _ in "" }
        let models = ModelManager(api: mock, config: env.config.ollama)
        let installed = try await models.installed()
        #expect(installed.map(\.remoteHost) == [Self.host, nil] && installed.map(\.roles) == [[], [.chat]],
                "a model that runs elsewhere is listed with where, and offered for no role")
        let profile = ModelProfile(name: "Cloud", position: 9, chatModel: Self.cloud, visionModel: "llava:13b:cloud", embedModel: Self.local)
        let status = try await models.status(for: profile)
        #expect(status.map(\.remoteHost) == [Self.host, ModelLocation.cloudPlace, nil],
                "the profile's models say which run elsewhere: listed so, or named for the cloud")
    }
}
