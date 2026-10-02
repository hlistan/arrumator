import CFNetwork
import Foundation
import Synchronization

/// Fails every request that is not on its way to the host its client allowed it (`allow(_:host:)`), a host on this Mac
/// or the local network (see `OllamaEndpoint`), and records it as a violation. Installed first on the only `URLSession`
/// the app creates (`session(transport:)`), so document data cannot reach any other machine. Each request carries the
/// one host its client was pointed at, so clients of different servers, as tests make, never widen each other's.
public final class NetworkGuardProtocol: URLProtocol {
    /// The key under which a request carries the host it may reach (`URLProtocol.property(forKey:in:)`).
    static let allowedHostKey = "dev.arrumator.allowedHost"

    private static let recorded = Mutex<[String]>([])

    public static var violations: [String] { recorded.withLock { $0 } }

    /// Lets `request` reach `host` alone, in the form `OllamaEndpoint.host(of:)` gives.
    static func allow(_ request: NSMutableURLRequest, host: String) {
        URLProtocol.setProperty(host, forKey: allowedHostKey, in: request)
    }

    /// Whether `request` goes where its client allowed it: its host is the one it carries, which is on this Mac or the
    /// local network. A request with no host allowed, or redirected to another host, is not.
    static func isAllowed(_ request: URLRequest) -> Bool {
        guard let host = request.url.flatMap(OllamaEndpoint.host(of:)),
              let allowed = property(forKey: allowedHostKey, in: request) as? String else { return false }
        return host == allowed && OllamaEndpoint.isLocal(host: host)
    }

    override public static func canInit(with request: URLRequest) -> Bool { !isAllowed(request) }
    override public static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let target = request.url?.absoluteString ?? "<nil>"
        Self.recorded.withLock { $0.append(target) }
        Log.error(.ollama, "Blocked non-local network request", ["url": target])
        client?.urlProtocol(self, didFailWithError: OllamaError.nonLocalHost(request.url?.host() ?? target))
    }

    override public func stopLoading() {}

    /// Every proxy switched off, so a request goes to the server it names and nowhere else. A session's
    /// `connectionProxyDictionary` that is nil uses the system's settings
    /// (https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary), whose
    /// exceptions need not cover the local network: a request to a server there would then go to the proxy, past this
    /// guard, which sees only the host the request names. Each kind is off when its key is present and zero
    /// (https://developer.apple.com/documentation/cfnetwork/kcfnetworkproxieshttpenable and its siblings).
    static let noProxies: [String: Int] = [
        kCFNetworkProxiesHTTPEnable as String: 0,
        kCFNetworkProxiesHTTPSEnable as String: 0,
        kCFNetworkProxiesSOCKSEnable as String: 0,
        kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
        kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0,
    ]

    /// Session configuration with the guard first, no proxy and no cache. `transport` is what tests put between the
    /// guard and the network, such as a stub server; the app passes none.
    static func guardedConfiguration(transport: [URLProtocol.Type]) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetworkGuardProtocol.self] + transport + (config.protocolClasses ?? [])
        config.connectionProxyDictionary = noProxies
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return config
    }

    /// The one session the app talks to Ollama through: guarded, with no proxy, and following no redirect, so a request
    /// leaves for the server it names by no route but the direct one.
    static func session(transport: [URLProtocol.Type]) -> URLSession {
        URLSession(configuration: guardedConfiguration(transport: transport), delegate: RedirectRefusal(), delegateQueue: nil)
    }
}

/// Refuses every redirect: the task then ends with the redirect's own response, which the client reports as
/// `OllamaError.redirected`, rather than sending the request, and the document it carries, where the server says.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
