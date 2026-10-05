import Foundation

/// Which models the app reads with: a name and three models, kept in `settings.json` under an id of its own
/// (`AppSettings.modelProfiles`). The bundled settings list Fast, Standard and Smart; the user's file holds only what was
/// changed of them, and any profile of the user's own.
public struct ModelProfile: Sendable, Codable, Hashable {
    /// What the profile is called where it is chosen; unique among the profiles, whatever its case.
    public var name: String
    /// Where the profile comes in the list, the lowest first: JSON objects keep no order.
    public var position: Int
    /// Reads documents and the requests of search tasks, and names files.
    public var chatModel: String
    /// Describes images, which are then read as documents are.
    public var visionModel: String
    /// Makes the vectors search by meaning uses, of documents and of what is searched for: documents embedded by another
    /// model are found by meaning only once they are read again.
    public var embedModel: String

    public init(name: String, position: Int, chatModel: String, visionModel: String, embedModel: String) {
        self.name = name
        self.position = position
        self.chatModel = chatModel
        self.visionModel = visionModel
        self.embedModel = embedModel
    }

    /// Its keys in `settings.json`.
    enum CodingKeys: String, CodingKey {
        case name, position, chatModel, visionModel, embedModel
    }
}

extension ModelProfile {
    /// The roles a profile gives a model, in the order Settings, the command line and History list them.
    public static let roles = ModelRole.allCases

    /// Where the profile keeps the model of `role`, and its key in `settings.json`: the one place a role is tied to its
    /// model, which the app, the command line, the checks of the settings and History all go by (`model(for:)`).
    static func field(of role: ModelRole) -> (path: WritableKeyPath<ModelProfile, String>, key: CodingKeys) {
        switch role {
        case .chat: (\.chatModel, .chatModel)
        case .vision: (\.visionModel, .visionModel)
        case .embedding: (\.embedModel, .embedModel)
        }
    }

    /// The model the profile gives `role`.
    public func model(for role: ModelRole) -> String { self[keyPath: Self.field(of: role).path] }

    /// The name as profiles are told apart by: without the space around it, whatever its case.
    var nameKey: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

/// What a change to a profile gives: its name, and a model for each role it names. What it does not give stays as it is.
public struct ModelProfileChange: Sendable, Hashable {
    public var name: String?
    /// The model the change gives each role it names.
    public var models: [ModelRole: String]

    public init(name: String? = nil, models: [ModelRole: String] = [:]) {
        self.name = name
        self.models = models
    }

    /// Whether the change gives nothing.
    public var isEmpty: Bool { name == nil && models.isEmpty }
}

/// A profile as the app and `arrumatorcli profiles` list it (`ModelProfileActions.list()`), with what the user may do
/// with it: a predefined one is changed and reset but never removed, a profile of the user's own is changed and removed.
public struct ModelProfileListing: Sendable, Codable, Hashable, Identifiable {
    /// Its key in `AppSettings.modelProfiles`, by which settings, tasks and commands name it.
    public var id: String
    public var profile: ModelProfile
    /// Its id is one the bundled settings list, so it is never removed: the bundled settings would bring it back.
    public var predefined: Bool
    /// A predefined profile the user changed, which can be reset to the bundled one.
    public var changed: Bool
    /// The profile Settings reads with (`AppSettings.profile`).
    public var inUse: Bool

    public init(id: String, profile: ModelProfile, predefined: Bool, changed: Bool, inUse: Bool) {
        self.id = id
        self.profile = profile
        self.predefined = predefined
        self.changed = changed
        self.inUse = inUse
    }
}

extension ModelProfileListing {
    /// Why the profile cannot be removed while `searchTasks` search tasks of the archive that is open read with it
    /// (`ModelProfileActions.searchTasks(readingWith:)`), or nil when it can: a predefined one, which the bundled settings
    /// would bring back, the one Settings reads with, and one tasks read with, which are given another first.
    /// `ModelProfileActions.remove(_:)` refuses what this says, and the app says it before it is asked.
    public func removalRefusal(searchTasks: Int) -> ModelProfileError? {
        if predefined { return .predefined(profile.name) }
        if inUse { return .inUse(profile.name) }
        if searchTasks > 0 { return .namedByTasks(profile.name, count: searchTasks) }
        return nil
    }
}

public enum ModelProfileError: Error, LocalizedError, Equatable {
    /// No profile has the id: one the settings do not list.
    case unknown(String)
    /// A profile is given a blank name: the name of the profile renamed, nil for a new one.
    case blankName(String?)
    /// The name is the one of the profile named `by` already, whatever its case.
    case nameTaken(name: String, by: String)
    /// The name has no letter or digit to make the new profile's id of.
    case nameWithoutLetterOrDigit(String)
    /// The profile of this name is given a blank model for the role.
    case blankModel(profile: String, role: ModelRole)
    /// The profile of this name is the user's own, so there is no bundled one to reset it to.
    case notPredefined(String)
    /// The profile of this name is predefined, so it is not removed: the bundled settings would bring it back at the next
    /// launch.
    case predefined(String)
    /// The profile of this name is the one Settings reads with.
    case inUse(String)
    /// The profile of this name is the one these many search tasks of the archive that is open read with; those of
    /// another archive are not known while it is closed.
    case namedByTasks(String, count: Int)

    /// Profiles are named by their names, as the app lists them, but for one there is none of, named as it was asked for.
    public var errorDescription: String? {
        switch self {
        case let .unknown(id): "There is no model profile “\(id)”"
        case let .blankName(name): (name.map { "The profile “\($0)”" } ?? "A new profile") + " needs a name; it cannot be blank"
        case let .nameTaken(name, by): "“\(name)” is the name of the profile “\(by)” already; each profile needs a name of its own, whatever its case"
        case let .nameWithoutLetterOrDigit(name): "“\(name)” has no letter or digit; give the profile a name with one"
        case let .blankModel(profile, role): "The profile “\(profile)” needs a model that \(Self.work(of: role)); it cannot be blank"
        case let .notPredefined(name): "“\(name)” is a profile of your own, with no bundled one to reset it to; change it or remove it instead"
        case let .predefined(name): "“\(name)” comes with Arrumator and would come back; change it or reset it instead"
        case let .inUse(name): "“\(name)” is the profile Settings reads with; choose another before removing it"
        case let .namedByTasks(name, count):
            "\(Format.count(count, "search task")) in this archive \(count == 1 ? "reads" : "read") with the profile “\(name)”; "
                + "give \(count == 1 ? "it" : "them") another profile first"
        }
    }

    /// What a model in the role does, as a reason says it.
    private static func work(of role: ModelRole) -> String {
        switch role {
        case .chat: "reads documents and requests"
        case .vision: "describes images"
        case .embedding: "finds documents by meaning"
        }
    }
}
