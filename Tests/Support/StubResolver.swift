import ArrumatorCore
import Foundation

/// Answers what a name stands for as a test says, as nothing in `swift test` may look a name up on the network: a name
/// it is given no addresses for does not resolve.
public struct StubResolver: HostResolving {
    private let answers: [String: [String]]

    public init(_ answers: [String: [String]] = [:]) { self.answers = answers }

    public func addresses(of host: String, within seconds: Double) async throws -> [String] { answers[host] ?? [] }
}
