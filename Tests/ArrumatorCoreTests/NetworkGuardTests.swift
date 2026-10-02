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
}
