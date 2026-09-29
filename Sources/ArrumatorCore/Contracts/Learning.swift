import Foundation

public enum CorrespondentOrigin: String, Sendable, Codable {
    case learned, user
}

/// Whom documents come from, as the app has learned to recognise them: by identifiers only ever on their documents,
/// by their e-mail and web domains, and by their names.
public struct Correspondent: Sendable, Codable, Identifiable, Hashable {
    public var id: Int64
    public var canonicalName: String
    public var country: String?
    /// Name variants seen in documents or entered by the user.
    public var aliases: [String]
    public var stableKeys: [String]
    public var emailDomains: [String]
    public var webDomains: [String]
    public var filedCount: Int
    public var origin: CorrespondentOrigin

    public init(id: Int64 = 0, canonicalName: String, country: String? = nil, aliases: [String] = [],
                stableKeys: [String] = [], emailDomains: [String] = [], webDomains: [String] = [],
                filedCount: Int = 0, origin: CorrespondentOrigin) {
        self.id = id
        self.canonicalName = canonicalName
        self.country = country
        self.aliases = aliases
        self.stableKeys = stableKeys
        self.emailDomains = emailDomains
        self.webDomains = webDomains
        self.filedCount = filedCount
        self.origin = origin
    }
}

/// Something the app learned that the user can make it forget.
public enum LearnedFact: Sendable, Codable, Hashable {
    /// Another name the user taught for a sender.
    case alias(correspondentID: Int64, alias: String)
    /// Everything known about a sender: names and identifiers.
    case sender(correspondentID: Int64)

    /// The fact a history event records, when it records one the user can forget.
    public static func recorded(by event: EventRecord) -> LearnedFact? {
        event.kind == .learned ? JSON.decode(LearnedFact.self, from: event.payloadJson) : nil
    }
}
