import Foundation
import Synchronization

/// Where Ollama runs a model: on the server the app talks to, or elsewhere. Ollama 0.18.2 sends a request elsewhere in
/// two ways, read in its source. A model whose name asks for its cloud, by a tag `cloud` or one ending in `-cloud`
/// (`parseSourceSuffix` in internal/modelref/modelref.go), goes to its cloud service, https://ollama.com:443, whatever
/// the server lists (server/cloud_proxy.go). A model whose manifest names a remote host, a cloud model pulled as a stub or
/// one made from it, is listed and described with `remote_model` and `remote_host` (`ListModelResponse`, `ShowResponse`
/// in api/types.go), and its chat handler forwards a request there (server/routes.go). Nothing is read with either
/// (AGENTS.md §4.1).
public enum ModelLocation {
    /// The tag, and the end of a tag, by which a model's name asks Ollama for its cloud.
    static let cloudTag = "cloud"
    static let cloudTagSuffix = "-cloud"
    /// Where a model named for Ollama's cloud runs, as the app says it.
    public static let cloudPlace = "Ollama's cloud service"

    /// Whether `model`'s name asks Ollama for its cloud, as Ollama reads it: by the tag after its last colon, `cloud`, or
    /// one that ends in `-cloud` and holds no `/`.
    public static func namesCloud(_ model: String) -> Bool {
        guard let colon = model.lastIndex(of: ":") else { return false }
        let written = model[model.index(after: colon)...]
        let tag = written.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tag == cloudTag || (!written.contains("/") && tag.hasSuffix(cloudTagSuffix))
    }

    /// Where Ollama runs `model` when not on its own server: its cloud, when the name asks for it, or the host the server
    /// gives (`said`, the `remote_host` of its listing or description); nil when the server runs it itself.
    public static func remoteHost(of model: String, said: String?) -> String? {
        let given = said.flatMap { $0.isEmpty ? nil : $0 }
        return namesCloud(model) ? given ?? cloudPlace : given
    }
}

/// What one client has learnt of where its server runs each model, by the model's full name: nil for the server itself,
/// else the host, with when it was said. It is the client's own, so it holds for one server, and a client made for
/// another address starts with none (`OllamaConnection.connect(to:)`). An answer is trusted for `maxAge` seconds of
/// `time` at most, as a model can be remade on the server meanwhile, such as from a cloud model.
final class ModelLocations: Sendable {
    private struct Said: Sendable {
        var host: String?
        var at: Date
    }

    private let known = Mutex<[String: Said]>([:])
    private let time: any TimeSource
    private let maxAge: Double

    init(time: any TimeSource, maxAge: Double) {
        self.time = time
        self.maxAge = maxAge
    }

    /// Where `model` runs, if it was said within `maxAge`: `.some(nil)` for the server itself.
    func location(of model: String) -> String?? {
        let now = time.now()
        return known.withLock { known in
            guard maxAge > 0, let said = known[ModelManager.normalized(model)], now.timeIntervalSince(said.at) <= maxAge else { return nil }
            return .some(said.host)
        }
    }

    /// Remembers what the server said of `model` just now: that it runs at `host`, or on the server itself when nil.
    func remember(_ model: String, runsAt host: String?) {
        let said = Said(host: host, at: time.now())
        known.withLock { $0[ModelManager.normalized(model)] = said }
    }

    /// Forgets what is known of `model`, as a download can change it.
    func forget(_ model: String) { _ = known.withLock { $0.removeValue(forKey: ModelManager.normalized(model)) } }
}
