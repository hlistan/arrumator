@testable import ArrumatorCore
import ArrumatorTesting
import CFNetwork
import Foundation
import Testing

/// The one session the app talks through lets a request leave for the server its client was pointed at, by the direct
/// route alone (AGENTS.md §4.1): not to another host, through no proxy, and, as `OllamaClientTests` shows, along no
/// redirect.
@Suite struct NetworkGuardTests {
    /// A request to `url` that its client allowed to reach `host`, or no host at all.
    private func request(_ url: URL, allowing host: String?) -> URLRequest {
        let request = NSMutableURLRequest(url: url)
        if let host { NetworkGuardProtocol.allow(request, host: host) }
        return request as URLRequest
    }

    @Test func aRequestReachesOnlyTheLocalHostItsClientAllowedIt() async throws {
        let server = try StubOllamaServer()
        server.reply(to: "/api/version", with: .json(#"{"version":"0.18.2"}"#))
        let session = NetworkGuardProtocol.session(transport: [StubOllamaServer.Transport.self])
        let url = server.baseURL.appending(path: "api/version")
        let host = try #require(OllamaEndpoint.host(of: server.baseURL))
        let (_, answered) = try await session.data(for: request(url, allowing: host))
        #expect((answered as? HTTPURLResponse)?.statusCode == 200, "the host its client allowed answers")
        let blocked: [(URLRequest, String)] = [
            (request(url, allowing: nil), "a request no client allowed anywhere"),
            (request(url, allowing: "192.168.1.239"), "a request allowed another host than the one it names"),
        ]
        for (request, what) in blocked {
            await #expect(throws: (any Error).self, "\(what) never leaves") { _ = try await session.data(for: request) }
        }
        #expect(server.requests.count == 1, "the server saw the allowed request alone")
        #expect(NetworkGuardProtocol.violations.filter { $0.contains(host) }.count == blocked.count, "and each refused one is recorded, for Doctor")
        let elsewhere = try #require(URL(string: "https://example.com/api/version"))
        await #expect(throws: (any Error).self, "a host beyond the local network is refused even when a request is allowed it") {
            _ = try await session.data(for: request(elsewhere, allowing: "example.com"))
        }
    }

    /// Each client's requests carry the server it was pointed at, so a client made for another server, as the app makes
    /// when it is pointed elsewhere and tests make all the time, neither blocks nor widens what another may reach.
    @Test func clientsOfDifferentServersReachTheirOwnAtOnce() async throws {
        let servers = try (0..<2).map { _ in try StubOllamaServer() }
        let config = try PipelineConfig.bundledDefaults().ollama
        for (index, server) in servers.enumerated() { server.reply(to: "/api/version", with: .json(#"{"version":"\#(index)"}"#)) }
        let clients = try servers.map { try OllamaClient(config: config, baseURL: $0.baseURL, time: TestTime(.blocks),
                                                         transport: [StubOllamaServer.Transport.self]) }
        _ = try OllamaClient(config: config, baseURL: try OllamaEndpoint.validated("http://192.168.1.239:11434"), time: TestTime(.blocks))
        let first = try await clients[0].version()
        let second = try await clients[1].version()
        #expect([first, second] == ["0", "1"], "each client reaches its own server, whatever clients were made since")
    }

    /// A system proxy whose exceptions do not cover the local network would take a request to the server there to the
    /// proxy, past the guard, which sees only the host a request names; the session uses none.
    @Test func theSessionPutsTheGuardFirstAndUsesNoProxy() throws {
        let config = NetworkGuardProtocol.guardedConfiguration(transport: [StubOllamaServer.Transport.self])
        let classes = (config.protocolClasses ?? []).map(ObjectIdentifier.init)
        #expect(classes.prefix(2) == [ObjectIdentifier(NetworkGuardProtocol.self), ObjectIdentifier(StubOllamaServer.Transport.self)],
                "the guard sees every request first, before anything a test puts between it and the network")
        let proxies = try #require(config.connectionProxyDictionary, "nil would leave the system's proxies in force")
        for key in [kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesSOCKSEnable,
                    kCFNetworkProxiesProxyAutoConfigEnable, kCFNetworkProxiesProxyAutoDiscoveryEnable] {
            #expect(proxies[key as String] as? Int == 0, "\(key) is off")
        }
        #expect(config.urlCache == nil, "and nothing is cached")
    }

    @Test func aLocalNameIsTrustedOnlyWhileItStandsForAddressesOnTheLocalNetwork() async throws {
        let url = try OllamaEndpoint.validated("http://ollama-box.local:11434")
        #expect(try await OllamaEndpoint.resolved(url, by: StubResolver(["ollama-box.local": ["192.168.1.20", "fe80::1%en0"]]), within: Self.lookup)
                    == ["192.168.1.20", "fe80::1%en0"], "a name on the local link, by any of its addresses there, zone and all")
        await #expect(throws: OllamaError.nameReachesBeyond(host: "ollama-box.local", beyond: ["203.0.113.7"], instead: "http://192.168.1.20:11434"),
                      "one that stands for an address beyond, as a machine there may answer to any name, is refused") {
            try await OllamaEndpoint.resolved(url, by: StubResolver(["ollama-box.local": ["192.168.1.20", "203.0.113.7"]]), within: Self.lookup)
        }
        #expect(try await OllamaEndpoint.resolved(url, by: StubResolver(), within: Self.lookup) == [],
                "one that does not resolve now stands for nothing yet")
        #expect(try await OllamaEndpoint.resolved(try OllamaEndpoint.validated("http://192.168.1.20:11434"), by: StubResolver(), within: Self.lookup)
                    == nil, "an address is checked by itself, with nothing to look up")
    }

    /// Seconds a test's lookups may take, which a stub answers at once.
    static let lookup = 1.0

    /// What mDNS answers for a machine on a home network with IPv6: link-local, private IPv4 and a global IPv6 address.
    static let dualStack = ["ollama-box.local": ["fe80::1c2b:3a4d:5e6f:7081%en0", "192.168.1.20", "2a01:4f8:c0c:1234::1"]]

    @Test func aLocalNameOnADualStackNetworkIsRefusedSayingWhichAddressToGive() async throws {
        let url = try OllamaEndpoint.validated("http://ollama-box.local:11434/ollama")
        let refusal = OllamaError.nameReachesBeyond(host: "ollama-box.local", beyond: ["2a01:4f8:c0c:1234::1"],
                                                    instead: "http://192.168.1.20:11434/ollama")
        await #expect(throws: refusal, "a request to the name may go to its global IPv6 address, through the router: never let it") {
            try await OllamaEndpoint.resolved(url, by: StubResolver(Self.dualStack), within: Self.lookup)
        }
        #expect(refusal.localizedDescription.contains("http://192.168.1.20:11434/ollama"),
                "the refusal says the address to give instead, its IPv4 address on the local network: \(refusal.localizedDescription)")
    }

    @Test(.timeLimit(.minutes(1))) func theSystemsLookupEndsWithinItsTimeAndWhenItIsCancelled() async throws {
        // A lookup that holds its thread until the test lets it go, as mDNS for a machine that is away may: nothing is
        // looked up on the network.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let held = SystemHostResolver { _ in
            release.wait()
            return ["192.168.1.20"]
        }
        #expect(try await held.addresses(of: Self.name, within: Self.short).isEmpty,
                "a lookup out of time is a name that does not resolve, whatever the lookup finds after")
        let waiting = Task { try await held.addresses(of: Self.name, within: Self.long) }
        waiting.cancel()
        await #expect(throws: CancellationError.self, "and one is given up as soon as what waits on it is cancelled") { try await waiting.value }
    }

    static let name = "ollama-box.local"
    /// Seconds of a lookup's time that run out at once, and that never run out in a test.
    static let short = 0.01
    static let long = 3600.0

    @Test func plainHTTPToAnotherMachineAndATrustedNameAreSaid() throws {
        #expect(OllamaEndpoint.cautions(for: try OllamaEndpoint.validated("http://ollama-box.local:11434"))
                    == [.unencrypted(host: "ollama-box.local"), .byName(host: "ollama-box.local")],
                "documents to another machine over plain HTTP cross the network unencrypted, to a machine trusted by its name")
        #expect(OllamaEndpoint.cautions(for: try OllamaEndpoint.validated("https://192.168.1.20:11434")).isEmpty,
                "over https to an address, there is nothing to say")
        #expect(OllamaEndpoint.cautions(for: try OllamaEndpoint.validated("http://127.0.0.1:11434")).isEmpty,
                "nor to this Mac, as nothing leaves it")
    }
}
