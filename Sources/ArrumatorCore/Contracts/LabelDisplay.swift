import Foundation

/// How labels are named and shown to the person, in one place, so the app's card and sidebar and History's summaries say
/// the same words (docs/using-arrumator.md). Each kind has one name, singular for a label of it and plural for a group of
/// them; the command line keeps its keys (`sender=`, `party=`, `object=`), which the docs map to these.
extension LabelKind {
    /// The kind's name for one label of it: "Sender", "Person or Organisation".
    public var name: String {
        switch self {
        case .sender: "Sender"
        case .party: "Person or Organisation"
        case .type: "Type"
        case .topic: "Topic"
        case .object: "Thing"
        case .reference: "Reference"
        case .date: "Date"
        case .period: "Period"
        case .deadline: "Deadline"
        case .amount: "Amount"
        case .jurisdiction: "Jurisdiction"
        case .language: "Language"
        case .tag: "Tag"
        }
    }

    /// The kind's name for the group of labels of it, as a heading: "Senders", "People and Organisations".
    public var groupName: String {
        switch self {
        case .sender: "Senders"
        case .party: "People and Organisations"
        case .type: "Types"
        case .topic: "Topics"
        case .object: "Things"
        case .reference: "References"
        case .date: "Dates"
        case .period: "Periods"
        case .deadline: "Deadlines"
        case .amount: "Amounts"
        case .jurisdiction: "Jurisdictions"
        case .language: "Languages"
        case .tag: "Tags"
        }
    }

    /// The name inside a sentence: "the new person or organisation label".
    public var sentenceName: String { name.lowercased() }
}

extension DocumentLabel {
    /// The label as the card and the sidebar show it, and History writes it: a type by its name, a language by its name in
    /// `locale`'s language, a date or deadline as a day and a period as its days, one way (`Format.day`, `Format.period`);
    /// anything else, and a value that cannot be read, as written. The locale is the caller's, never read from the Mac.
    public func shown(locale: Locale) -> String {
        switch kind {
        case .language: locale.localizedString(forLanguageCode: value) ?? value
        case .type: DocumentType(rawValue: value)?.label ?? value
        case .date, .deadline: Format.day(value, locale: locale) ?? value
        case .period: Format.period(value, locale: locale) ?? value
        case .sender, .party, .topic, .object, .reference, .amount, .jurisdiction, .tag: value
        }
    }
}
