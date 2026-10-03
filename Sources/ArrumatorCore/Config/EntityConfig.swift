/// Finding a document's dates and identifiers: the words that label them and how dates are weighed.
public struct EntityConfig: Sendable, Codable, Hashable {
    public struct Scores: Sendable, Codable, Hashable {
        public var label: Double
        public var firstPortion: Double
        public var plausibleYear: Double
        public var dueLabel: Double
        public var birthLabel: Double
        public var crowdedLine: Double
        public var matchesMetadata: Double
    }
    public var dateLabels: [String]
    public var dueLabels: [String]
    public var birthLabels: [String]
    /// Words after which a number is an account or customer number (`Customer number`, `N.º de cliente`, `Лицевой счёт`).
    public var accountLabels: [String]
    /// Words after which a number is a policy or contract number (`Policy No`, `Apólice`, `Номер договора`).
    public var policyLabels: [String]
    /// How a number sign is written between a label and its number (`n. º.`, `№`, `nr.`, `número`).
    public var numberSigns: [String]
    public var labelWindowChars: Int
    public var yearsBack: Int
    public var yearsForward: Int
    public var scores: Scores
    public var firstPortionShare: Double
    /// Number of dates on one line from which the line counts as crowded (tables, statements).
    public var crowdedLineDates: Int
    /// Minimum score for a date found in the text to be chosen over metadata dates.
    public var minTextDateScore: Double
}

extension EntityConfig {
    /// Phrases a label could not be matched by (`LabelPhrases.problem`): one of nothing but `*`, which would take every
    /// word for a label, or one reaching more than `LabelPhrases.maxAnyWords` words from it; and a number sign of any
    /// word, which is no sign at all.
    var problems: [String] {
        let lists: [(key: String, phrases: [String])] = [
            ("dateLabels", dateLabels), ("dueLabels", dueLabels), ("birthLabels", birthLabels),
            ("accountLabels", accountLabels), ("policyLabels", policyLabels), ("numberSigns", numberSigns),
        ]
        var problems: [String] = []
        for (key, phrases) in lists {
            for phrase in phrases {
                if let problem = LabelPhrases.problem(phrase) {
                    problems.append("entities.\(key): \"\(phrase)\" \(problem)")
                } else if key == "numberSigns", phrase.split(separator: " ").contains(Substring(LabelPhrases.anyWord)) {
                    problems.append("entities.numberSigns: \"\(phrase)\" holds \(LabelPhrases.anyWord), and a number sign is written as it is")
                }
            }
        }
        return problems
    }
}
