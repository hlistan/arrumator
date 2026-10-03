import ArrumatorCore
import Foundation
import Synchronization

/// Raw entities found in a text, before the document date is resolved.
public struct EntityScan: Sendable {
    public var dateCandidates: [DateCandidate]
    public var stableKeys: [StableKey]
}

/// Pure entity extraction: dates (`DateScanner`) and checksum-validated identifiers (`StableKeys`). Everything else a
/// document says, its amounts and parties among them, is read by the model.
public struct EntityExtractor: Sendable {
    private let config: EntityConfig
    private let stableKeys: StableKeys

    public init(config: EntityConfig) {
        self.config = config
        stableKeys = StableKeys(labels: config)
    }

    /// - Parameter now: today, which decides how a two-digit year is read, in `calendar`'s years.
    public func scan(_ text: String, now: Date, calendar: GregorianCalendar) -> EntityScan {
        let pivot = calendar.year(of: now) + config.yearsForward
        return EntityScan(dateCandidates: DateScanner(twoDigitYearPivot: pivot).candidates(in: text),
                          stableKeys: stableKeys.detect(in: text))
    }
}

/// The entity extractor of the configuration files are read with, built once for it: its identifier rules are compiled
/// regular expressions, the same for every file until the configuration changes.
final class EntityExtractors: Sendable {
    private let last = Mutex<(config: EntityConfig, extractor: EntityExtractor)?>(nil)

    func extractor(for config: EntityConfig) -> EntityExtractor {
        last.withLock { last in
            if let last, last.config == config { return last.extractor }
            let extractor = EntityExtractor(config: config)
            last = (config, extractor)
            return extractor
        }
    }
}

extension Array where Element: Hashable {
    /// Elements in original order without repeats.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
