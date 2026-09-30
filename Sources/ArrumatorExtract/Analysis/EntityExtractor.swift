import ArrumatorCore
import Foundation

/// Raw entities found in a text, before the document date is resolved.
public struct EntityScan: Sendable {
    public var dateCandidates: [DateCandidate]
    public var stableKeys: [StableKey]
}

/// Pure entity extraction: dates (`DateScanner`) and checksum-validated identifiers (`StableKeys`). Everything else a
/// document says, its amounts and parties among them, is read by the model.
public struct EntityExtractor: Sendable {
    private let config: EntityConfig

    public init(config: EntityConfig) {
        self.config = config
    }

    /// - Parameter now: today, which decides how a two-digit year is read.
    public func scan(_ text: String, now: Date, calendar: Calendar) -> EntityScan {
        let pivot = calendar.component(.year, from: now) + config.yearsForward
        return EntityScan(dateCandidates: DateScanner(twoDigitYearPivot: pivot).candidates(in: text),
                          stableKeys: StableKeys.detect(in: text))
    }
}

extension Array where Element: Hashable {
    /// Elements in original order without repeats.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
