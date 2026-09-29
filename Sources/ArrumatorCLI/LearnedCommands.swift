import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Senders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Senders the app has learned: names, other names and identifiers.")
    @OptionGroup var options: GlobalOptions
    func run() async throws {
        let runtime = try await options.runtime()
        let senders = try await runtime.senders.correspondents().sorted { $0.filedCount > $1.filedCount }
        options.emit(senders) {
            senders.isEmpty ? "No senders learned yet." : Terminal.table(senders.map { c in
                ["#\(c.id)", c.canonicalName, "\(c.filedCount) filed",
                 c.stableKeys.isEmpty ? "" : "by " + c.stableKeys.joined(separator: ", "),
                 c.aliases.isEmpty ? "" : "also “" + c.aliases.joined(separator: "”, “") + "”"]
            })
        }
    }
}

struct Forget: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make the app forget something it learned about a sender.",
        subcommands: [Alias.self, Sender.self])

    struct Alias: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget another name taught for a sender.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Sender number from `arrumatorcli senders`.") var sender: Int64
        @Argument var alias: String
        func run() async throws { try await options.runtime().learner.forget(.alias(correspondentID: sender, alias: alias)) }
    }

    struct Sender: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget everything known about a sender.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Sender number from `arrumatorcli senders`.") var sender: Int64
        func run() async throws { try await options.runtime().learner.forget(.sender(correspondentID: sender)) }
    }
}
