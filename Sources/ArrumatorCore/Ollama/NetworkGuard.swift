import Foundation
import Synchronization

/// Fails every request whose host is not the Ollama server the app was pointed at (this Mac, or one on the local
/// network; see `OllamaEndpoint`) and records it as a violation. Installed on the only `URLSession` the app creates,
/// so document data cannot reach any other machine.
public final class NetworkGuardProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var allowedHosts: Set<String> = []
        var violations: [String] = []
    }
    private static let state = Mutex(State())

    public static func configure(allowedHosts: [String]) {
        state.withLock { $0.allowedHosts = Set(allowedHosts.map { $0.lowercased() }) }
    }

    public static var violations: [String] { state.withLock { $0.violations } }
    public static func resetViolations() { state.withLock { $0.violations.removeAll() } }

    static func isAllowed(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return state.withLock { $0.allowedHosts.contains(bare) }
    }

    override public static func canInit(with request: URLRequest) -> Bool { !isAllowed(request.url) }
    override public static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let target = request.url?.absoluteString ?? "<nil>"
        Self.state.withLock { $0.violations.append(target) }
        Log.error(.ollama, "Blocked non-local network request", ["url": target])
        client?.urlProtocol(self, didFailWithError: OllamaError.nonLocalHost(request.url?.host() ?? target))
    }

    override public func stopLoading() {}

    /// Session configuration with the guard installed and caching disabled.
    public static func guardedConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetworkGuardProtocol.self] + (config.protocolClasses ?? [])
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return config
    }
}
