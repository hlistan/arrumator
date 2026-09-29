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

    /// `address` as a URL, when it names this Mac or the local network.
    public static func validated(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            throw OllamaError.invalidBaseURL(address)
        }
        guard isLocal(host: host) else { throw OllamaError.nonLocalHost(host) }
        return url
    }

    /// Whether `url` is this Mac itself, where the app may start Ollama; another machine's server is left alone.
    public static func isThisMac(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        let bare = unbracketed(host)
        if bare == localhostName { return true }
        if let v4 = IPv4.bytes(bare) { return v4.first == IPv4.loopbackFirstOctet }
        if let v6 = IPv6.bytes(bare) { return IPv6.isLoopback(v6) }
        return false
    }

    static func isLocal(host: String) -> Bool {
        let bare = unbracketed(host)
        if bare == localhostName || bare.hasSuffix(localLinkSuffix) { return true }
        if let v4 = IPv4.bytes(bare) { return IPv4.isLocal(v4) }
        if let v6 = IPv6.bytes(bare) { return IPv6.isLocal(v6) }
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
