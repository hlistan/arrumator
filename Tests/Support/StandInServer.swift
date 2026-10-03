import Foundation

/// A stand-in for `ollama serve`: a script that adds its process number to a file, a line each time it is started, and
/// then waits, as a server does, until it is stopped. What the app's Ollama lifecycle spawns in a test in place of
/// the user's Ollama, which a test never starts.
public struct StandInServer: Sendable {
    /// The script, to give as the Ollama binary (`ollamaBinaryPath`, `OllamaLifecycle.configure`).
    public let executable: URL
    /// Where each start writes its process number.
    public let processNumbers: URL

    /// How long the stand-in lives if nothing stops it: far longer than any test waits for it.
    public static let lifetime = 300
    static let executablePermissions = 0o755

    /// Writes the script into `folder`, which must exist.
    public init(in folder: URL) throws {
        executable = folder.appendingPathComponent("serve")
        processNumbers = folder.appendingPathComponent("serve.pid")
        try Data("#!/bin/sh\necho $$ >> '\(processNumbers.path)'\nexec /bin/sleep \(Self.lifetime)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: Self.executablePermissions], ofItemAtPath: executable.path)
    }

    /// The process number of each start so far, in order.
    public var started: [pid_t] {
        ((try? String(contentsOf: processNumbers, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
    }

    /// Whether the process `pid` still runs.
    public static func runs(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
}
