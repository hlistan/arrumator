import ArrumatorCore

/// What refused a configuration, however it was refused: a change to it (`ConfigError.invalid`) or the files that give it
/// (`ConfigError.invalidFile`), with the paths of those files, none for a change.
public struct ConfigRefusal: Equatable, Sendable {
    public let name: String
    public let underlying: String
    public let paths: [String]

    public init?(_ error: any Error) {
        switch error as? ConfigError {
        case let .invalid(name, underlying)?: (self.name, self.underlying, paths) = (name, underlying, [])
        case let .invalidFile(name, paths, underlying, _)?: (self.name, self.underlying, self.paths) = (name, underlying, paths)
        default: return nil
        }
    }
}
