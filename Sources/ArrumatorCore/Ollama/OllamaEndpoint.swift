import Foundation

/// Where Ollama answers: this Mac, or a machine of the user's own on the local network — never the internet, so
/// document text only reaches machines the user runs. An address qualifies when it is loopback, private or
/// link-local, or the name `localhost` or a `.local` name; anything else is refused.
public enum OllamaEndpoint {
    /// Schemes Ollama is reached over.
    static let schemes: Set<String> = ["http", "https"]
    /// The name this Mac answers to, and the suffix of multicast DNS names on the local link (RFC 6762).
    static let localhostName = "localhost"
    static let localLinkSuffix = ".local"

    /// Why an address cannot be used, said without the address, which may hold a password. A user name or password
    /// would reach the log and History with the address, and a query or fragment means nothing to Ollama; a host
    /// written with escapes is one host when checked and another when compared.
    public enum Problem: String, Sendable, Hashable {
        case unreadable = "it does not read as an address"
        case scheme = "its scheme is not http or https"
        case noHost = "it names no host"
        case escapedHost = "its host is written with percent escapes"
        case userInfo = "it has a user name or password"
        case query = "it has a query"
        case fragment = "it has a fragment"
    }

    /// Where the address the app talks to came from, which an address that cannot be used is reported with.
    public enum Source: Sendable, Hashable {
        /// The setting `ollamaURL`, saved in this settings file.
        case settings(URL)
        /// The variable `RuntimeEnvironment.ollamaURLVariable`.
        case environment
    }

    /// An address an error suggests, the one Ollama listens on at this Mac.
    static let example = "http://127.0.0.1:11434"

    /// `address`, which came from `source`, as `validated` takes it; an address it refuses is reported as
    /// `OllamaError.unusableAddress`, saying where it came from and how to give another.
    public static func validated(_ address: String, from source: Source) throws -> URL {
        do {
            return try validated(address)
        } catch {
            throw OllamaError.unusableAddress(source, reason: error.localizedDescription)
        }
    }

    /// `address` as a URL, when it names this Mac or the local network by a scheme, a host, a port and a path alone.
    public static func validated(_ address: String) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OllamaError.invalidAddress(.unreadable)
        }
        _ = try localHost(of: url)
        return url
    }

    /// The host of `url`, in the form `host(of:)` gives, when `url` names this Mac or the local network by a scheme, a
    /// host, a port and a path alone. What is wrong is said without the address (`Problem`).
    static func localHost(of url: URL) throws -> String {
        if url.user(percentEncoded: true) != nil || url.password(percentEncoded: true) != nil {
            throw OllamaError.invalidAddress(.userInfo)
        }
        if url.query(percentEncoded: true) != nil { throw OllamaError.invalidAddress(.query) }
        if url.fragment(percentEncoded: true) != nil { throw OllamaError.invalidAddress(.fragment) }
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { throw OllamaError.invalidAddress(.scheme) }
        guard let written = url.host(percentEncoded: true), !written.isEmpty else { throw OllamaError.invalidAddress(.noHost) }
        guard let host = host(of: url) else { throw OllamaError.invalidAddress(.escapedHost) }
        guard isLocal(host: host) else { throw OllamaError.nonLocalHost(host) }
        return host
    }

    /// The host of `url` in the one form it is checked in, allowed in and compared in everywhere (`validated`,
    /// `OllamaClient`, `NetworkGuardProtocol`): as the URL writes it, lowercased, without the brackets of an IPv6
    /// address. A host written with percent escapes has none: read decoded it is one host, and as written another, so
    /// what was checked would not be what is compared or reached.
    static func host(of url: URL) -> String? {
        guard let written = url.host(percentEncoded: true), written == url.host(percentEncoded: false) else { return nil }
        let host = unbracketed(written.lowercased())
        return host.isEmpty ? nil : host
    }

    /// Whether `url` is this Mac itself, where the app may start Ollama; another machine's server is left alone.
    public static func isThisMac(_ url: URL) -> Bool {
        guard let host = host(of: url) else { return false }
        if host == localhostName { return true }
        if let v4 = IPv4.bytes(host) { return v4.first == IPv4.loopbackFirstOctet }
        if let v6 = IPv6.bytes(host) { return IPv6.isLoopback(v6) }
        return false
    }

    /// What the user is told of an address the app accepts: a warning, never a refusal (Settings › Models, `doctor`).
    public enum Caution: Sendable, Hashable {
        /// Plain HTTP to another machine: documents cross the local network unencrypted.
        case unencrypted(host: String)
        /// A `.local` name, taken for the local network by its name: what it stands for is looked up when the user
        /// chooses it (`ArrumatorRuntime.useOllama(at:)`) and by the doctor, not before each request.
        case byName(host: String)

        public var summary: String {
            switch self {
            case let .unencrypted(host):
                "Documents go to \(host) over plain HTTP, unencrypted: anyone who can watch the local network can read them. "
                    + "Use https when the server offers it."
            case let .byName(host):
                "\(host) is taken for a machine on the local network by its name; what it stands for is checked when you "
                    + "choose it and by arrumatorcli doctor, not before each request."
            }
        }
    }

    /// What the user is told of `url`, an address `validated` accepts.
    public static func cautions(for url: URL) -> [Caution] {
        guard let host = host(of: url), !isThisMac(url) else { return [] }
        var cautions: [Caution] = []
        if url.scheme?.lowercased() == plainScheme { cautions.append(.unencrypted(host: host)) }
        if host.hasSuffix(localLinkSuffix) { cautions.append(.byName(host: host)) }
        return cautions
    }

    /// The scheme that sends a request unencrypted.
    static let plainScheme = "http"

    /// What the `.local` name of `url` stands for now, by `resolver` within `seconds` (`ollama.timeouts.resolve`): its
    /// addresses, each on this Mac or the local network, or none when it does not resolve in time, as when the machine is
    /// away. Nil for an address that is no `.local` name, which `validated` has checked by itself.
    ///
    /// A request to the name goes to whichever of its addresses the system picks, an IPv6 one first when it has one
    /// (Happy Eyeballs, RFC 8305), so a name that stands for any address beyond the local network is refused
    /// (`OllamaError.nameReachesBeyond`), even beside local ones: a machine on a network with IPv6 often has a global
    /// address too, which a request would reach through the router. The refusal says the address to give instead: its
    /// IPv4 address on the local network, with the port and path of `url`, when it has one.
    public static func resolved(_ url: URL, by resolver: any HostResolving, within seconds: Double) async throws -> [String]? {
        guard let host = host(of: url), host.hasSuffix(localLinkSuffix) else { return nil }
        let addresses = try await resolver.addresses(of: host, within: seconds)
        // An IPv6 address on the local link names its zone, which says which interface, not where.
        let bare = { (address: String) in String(address.prefix { $0 != zoneSeparator }) }
        let beyond = addresses.filter { !isLocal(host: bare($0)) }
        guard beyond.isEmpty else {
            let local = addresses.first { IPv4.bytes($0).map(IPv4.isLocal) == true }
            throw OllamaError.nameReachesBeyond(host: host, beyond: beyond, instead: local.flatMap { address(url, host: $0) })
        }
        return addresses
    }

    /// `url` with the IPv4 address `host` in place of its host, as an address to give.
    static func address(_ url: URL, host: String) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = host
        return components.url?.absoluteString
    }

    /// What separates an IPv6 address from its zone (RFC 6874).
    static let zoneSeparator: Character = "%"

    /// Whether `host`, in the form `host(of:)` gives, is this Mac or the local network.
    static func isLocal(host: String) -> Bool {
        if host == localhostName || host.hasSuffix(localLinkSuffix) { return true }
        if let v4 = IPv4.bytes(host) { return IPv4.isLocal(v4) }
        if let v6 = IPv6.bytes(host) { return IPv6.isLocal(v6) }
        return false
    }

    private static func unbracketed(_ host: String) -> String { host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }

    /// IPv4 blocks that never leave the local network: loopback 127/8, private 10/8, 172.16/12 and 192.168/16
    /// (RFC 1918), and link-local 169.254/16 (RFC 3927).
    enum IPv4 {
        static let loopbackFirstOctet: UInt8 = 127

        /// The address's four bytes, when `text` is an IPv4 address (parsed by `inet_pton`, without networking).
        static func bytes(_ text: String) -> [UInt8]? {
            var address = in_addr()
            guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
            return withUnsafeBytes(of: address) { Array($0) }
        }

        static func isLocal(_ bytes: [UInt8]) -> Bool {
            guard bytes.count == 4 else { return false }
            switch (bytes[0], bytes[1]) {
            case (loopbackFirstOctet, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
    }

    /// IPv6 blocks that never leave the local network: loopback ::1, unique local fc00::/7 (RFC 4193) and link-local
    /// fe80::/10 (RFC 4291).
    enum IPv6 {
        /// The address's sixteen bytes, when `text` is an IPv6 address.
        static func bytes(_ text: String) -> [UInt8]? {
            var address = in6_addr()
            guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
            return withUnsafeBytes(of: address) { Array($0) }
        }

        static func isLoopback(_ bytes: [UInt8]) -> Bool { bytes.count == 16 && bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1 }

        static func isLocal(_ bytes: [UInt8]) -> Bool {
            guard bytes.count == 16 else { return false }
            if isLoopback(bytes) { return true }
            if bytes[0] & 0xFE == 0xFC { return true }
            return bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
        }
    }
}
