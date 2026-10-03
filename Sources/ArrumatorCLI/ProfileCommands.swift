import ArgumentParser
import ArrumatorCore
import ArrumatorRuntime
import Foundation

struct Profiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Model profiles: which models read documents and requests, describe images and find by meaning. "
            + "List, add, change, reset and remove them; `settings --profile` chooses the one Settings reads with.",
        subcommands: [List.self, Add.self, Update.self, Reset.self, Remove.self], defaultSubcommand: List.self)

    /// The models a profile is given, by their roles.
    struct RoleModels: ParsableArguments {
        @Option(help: "The model that reads documents and requests, and names files.") var chatModel: String?
        @Option(help: "The model that describes images.") var visionModel: String?
        @Option(help: "The model that finds documents by meaning. Documents read before are found by meaning again only once they are read again.")
        var embedModel: String?

        /// The model given for each role, by the option that names it.
        var given: [ModelRole: String] { [.chat: chatModel, .vision: visionModel, .embedding: embedModel].compactMapValues { $0 } }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Every model profile, by its position: its id, name and models, the one in use, the predefined ones and those changed.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let listings = try await options.runtime().profiles.list()
            try options.emit(listings) { Terminal.profiles(listings) }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a profile of your own: a copy of another, with the models given, under an id made of its name.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "The profile to copy, by its id as `arrumatorcli profiles` lists it; the one Settings reads with if not given.")
        var from: String?
        @OptionGroup var models: RoleModels
        @Argument(help: "Its name, unique among the profiles whatever its case, such as \"Mine\".") var name: String

        func run() async throws {
            let added = try await options.runtime().profiles.add(name: name, copying: from, change: ModelProfileChange(models: models.given))
            try options.emit(added) { Terminal.profiles([added]) }
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rename a profile or give it other models; a predefined one keeps what you change until it is reset.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "Its name, unique among the profiles whatever its case.") var name: String?
        @OptionGroup var models: RoleModels
        @Argument(help: "The profile, by its id as `arrumatorcli profiles` lists it.") var profile: String

        func validate() throws {
            if ModelProfileChange(name: name, models: models.given).isEmpty {
                throw ValidationError("Give --name, --chat-model, --vision-model or --embed-model")
            }
        }

        func run() async throws {
            let updated = try await options.runtime().profiles.update(profile, ModelProfileChange(name: name, models: models.given))
            try options.emit(updated) { Terminal.profiles([updated]) }
        }
    }

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set a predefined profile back to the one the app comes with.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The predefined profile, by its id as `arrumatorcli profiles` lists it.") var profile: String

        func run() async throws {
            let reset = try await options.runtime().profiles.reset(profile)
            try options.emit(reset) { Terminal.profiles([reset]) }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a profile of your own; not a predefined one, the one Settings reads with, or one search tasks of this archive "
                + "read with. A task of another archive whose profile is gone fails saying so until it is given another.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "The profile, by its id as `arrumatorcli profiles` lists it.") var profile: String

        func run() async throws {
            let removed = try await options.runtime().profiles.remove(profile)
            try options.emit(removed) { "Removed the profile “\(removed.profile.name)” (\(removed.id))" }
        }
    }
}

extension Terminal {
    /// Profiles as a table, one per line under a header: id, name, the models of the three roles, and whether it is the
    /// one in use, predefined, changed, or the user's own.
    static func profiles(_ listings: [ModelProfileListing]) -> String {
        table([["profile", "name", "reads with", "describes images with", "finds by meaning with", ""]] + listings.map { listing in
            let kind = listing.predefined ? (listing.changed ? ["predefined", "changed"] : ["predefined"]) : ["yours"]
            return [listing.id, listing.profile.name] + ModelProfile.roles.map(listing.profile.model(for:))
                + [((listing.inUse ? ["in use"] : []) + kind).joined(separator: " · ")]
        })
    }
}
