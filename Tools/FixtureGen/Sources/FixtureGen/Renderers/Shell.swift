import Foundation

enum ShellError: Error, CustomStringConvertible {
    case failed(tool: String, status: Int32, message: String)

    var description: String {
        switch self {
        case .failed(let tool, let status, let message): "\(tool) exited with \(status): \(message)"
        }
    }
}

/// Runs system tools (`zip`, `unzip`) synchronously with a fixed environment.
enum Shell {
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil,
                    environment: [String: String] = [:]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"].merging(environment) { $1 }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Drain stdout before waiting so a large output cannot block the child; zip and unzip write at most a
        // few lines to stderr, which the pipe buffer holds until it is read below.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShellError.failed(tool: tool, status: process.terminationStatus,
                                    message: String(decoding: message, as: UTF8.self))
        }
        return data
    }
}
