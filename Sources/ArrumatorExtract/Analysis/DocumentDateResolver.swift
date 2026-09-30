import ArrumatorCore
import Foundation

/// Facts besides the text that bear on the document date.
public struct DateEvidence: Sendable {
    /// UTF-16 length of page 1 (nil = whole text counts as the first page).
    public var firstPageLength: Int?
    public var metadataDates: [MetadataDate]
    public var fileCreated: Date?
    public var fileModified: Date?
    public var now: Date
    public var calendar: Calendar

    public init(firstPageLength: Int?, metadataDates: [MetadataDate], fileCreated: Date?, fileModified: Date?,
                now: Date, calendar: Calendar) {
        self.firstPageLength = firstPageLength
        self.metadataDates = metadataDates
        self.fileCreated = fileCreated
        self.fileModified = fileModified
        self.now = now
        self.calendar = calendar
    }
}

/// One scored occurrence of a date, with the reasons for its score (recorded in traces for tuning).
public struct ScoredDate: Sendable, Encodable {
    public var date: String
    public var score: Double
    public var label: String?
    public var reasons: [String]
    public var offset: Int
    public var context: String
    public var eligible: Bool
}

public struct DateResolution: Sendable, Encodable {
    /// Unique text dates, best first.
    public var ranked: [DetectedDate]
    /// Every scored occurrence, in text order.
    public var scored: [ScoredDate]
    public var chosen: DetectedDate?
}

/// Chooses the document (issue) date among the dates found in the text and the file's metadata dates.
///
/// Every text occurrence is scored with `EntityConfig`: a date label just before it (`Data de emissão`, `Дата`,
/// `Invoice date`) adds `scores.label`; due-date and birth-date labels add their (negative) scores; being in the
/// first `firstPortionShare` of page 1, having a plausible year and equalling an EXIF/PDF metadata date add
/// bonuses; a line holding `crowdedLineDates` or more dates (tables, statements) is penalised. The label that
/// counts is the one closest to the date on the same or previous line, with no other date in between. The best
/// eligible text date wins if it reaches `minTextDateScore`; otherwise EXIF, PDF metadata, file creation and
/// modification dates are used in that order.
public struct DocumentDateResolver: Sendable {
    private enum LabelKind: String {
        case date, due, birth
    }

    private let config: EntityConfig
    private let labels: [(kind: LabelKind, regex: NSRegularExpression)]

    public init(config: EntityConfig) {
        self.config = config
        labels = [(.date, config.dateLabels), (.due, config.dueLabels), (.birth, config.birthLabels)]
            .compactMap { kind, words in Self.labelRegex(words).map { (kind, $0) } }
    }

    public func resolve(_ candidates: [DateCandidate], in text: String, evidence: DateEvidence) -> DateResolution {
        let ns = text as NSString
        let lineStarts = Self.lineStarts(ns)
        let currentYear = evidence.calendar.component(.year, from: evidence.now)
        let plausibleYears = (currentYear - config.yearsBack)...(currentYear + config.yearsForward)
        let firstPortionEnd = Double(evidence.firstPageLength ?? ns.length) * config.firstPortionShare
        let metadataDays = Set(evidence.metadataDates.map(\.day))
        let sorted = candidates.sorted { $0.location < $1.location }
        let lineOf = sorted.map { Self.lineIndex(of: $0.location, in: lineStarts) }
        var datesPerLine: [Int: Int] = [:]
        for line in lineOf { datesPerLine[line, default: 0] += 1 }

        var scored: [ScoredDate] = []
        var best: [CalendarDay: (score: ScoredDate, source: DateSource)] = [:]
        for (index, candidate) in sorted.enumerated() {
            let line = lineOf[index]
            var windowStart = max(candidate.location - config.labelWindowChars, lineStarts[max(0, line - 1)])
            if index > 0 { windowStart = max(windowStart, sorted[index - 1].end) }
            let window = NSRange(location: windowStart, length: max(0, candidate.location - windowStart))
            let label = nearestLabel(in: text, window: window)

            var score = 0.0
            var reasons: [String] = []
            if let label {
                let delta = switch label.kind {
                case .date: config.scores.label
                case .due: config.scores.dueLabel
                case .birth: config.scores.birthLabel
                }
                score += delta
                reasons.append("\(label.kind.rawValue)Label \(label.text)")
            }
            if Double(candidate.location) < firstPortionEnd {
                score += config.scores.firstPortion
                reasons.append("firstPortion")
            }
            let plausible = plausibleYears.contains(candidate.day.year)
            if plausible {
                score += config.scores.plausibleYear
                reasons.append("plausibleYear")
            }
            let lineDates = datesPerLine[line, default: 0]
            if lineDates >= config.crowdedLineDates {
                score += config.scores.crowdedLine
                reasons.append("crowdedLine \(lineDates)")
            }
            if metadataDays.contains(candidate.day) {
                score += config.scores.matchesMetadata
                reasons.append("matchesMetadata")
            }
            let context = Self.squeeze(ns.substring(with: NSRange(location: windowStart,
                                                                  length: candidate.end - windowStart)))
            let entry = ScoredDate(date: candidate.day.iso, score: score, label: label?.text, reasons: reasons,
                                   offset: candidate.location, context: context, eligible: plausible)
            scored.append(entry)
            let source: DateSource = label?.kind == .date ? .label : .prominence
            if let existing = best[candidate.day], existing.score.score >= score { continue }
            best[candidate.day] = (entry, source)
        }

        let ranked = best.values
            .sorted { $0.score.score != $1.score.score ? $0.score.score > $1.score.score : $0.score.offset < $1.score.offset }
        let detected = ranked.map {
            DetectedDate(date: $0.score.date, score: $0.score.score, source: $0.source, context: $0.score.context)
        }
        let textChoice = ranked.first { $0.score.eligible && $0.score.score >= config.minTextDateScore }
            .map { DetectedDate(date: $0.score.date, score: $0.score.score, source: $0.source, context: $0.score.context) }
        let chosen = textChoice ?? fallback(evidence, plausibleYears: plausibleYears)
        return DateResolution(ranked: detected, scored: scored, chosen: chosen)
    }

    // MARK: Fallbacks

    private func fallback(_ evidence: DateEvidence, plausibleYears: ClosedRange<Int>) -> DetectedDate? {
        for source in [DateSource.exif, .pdfMeta] {
            if let meta = evidence.metadataDates.first(where: { $0.source == source && plausibleYears.contains($0.day.year) }) {
                return DetectedDate(date: meta.day.iso, score: 0, source: source, context: meta.label)
            }
        }
        let fileDates: [(Date?, DateSource, String)] = [
            (evidence.fileCreated, .fileCreated, "file creation date"),
            (evidence.fileModified, .mtime, "file modification date"),
        ]
        for (date, source, label) in fileDates {
            guard let date else { continue }
            let day = CalendarDay(date: date, calendar: evidence.calendar)
            return DetectedDate(date: day.iso, score: 0, source: source, context: label)
        }
        return nil
    }

    // MARK: Labels

    private struct FoundLabel {
        var kind: LabelKind
        var text: String
        var end: Int
        var length: Int
    }

    /// The label ending closest to the date inside `window`; on a tie the longer label wins
    /// (`Data de nascimento` over `Data`).
    private func nearestLabel(in text: String, window: NSRange) -> FoundLabel? {
        guard window.length > 0 else { return nil }
        let ns = text as NSString
        var nearest: FoundLabel?
        for (kind, regex) in labels {
            for match in regex.matches(in: text, range: window) {
                let found = FoundLabel(kind: kind, text: ns.substring(with: match.range),
                                       end: NSMaxRange(match.range), length: match.range.length)
                if let current = nearest, current.end > found.end || (current.end == found.end && current.length >= found.length) {
                    continue
                }
                nearest = found
            }
        }
        return nearest
    }

    /// Whole-word, case-insensitive alternation of `words` (longest first; spaces match any whitespace run).
    private static func labelRegex(_ words: [String]) -> NSRegularExpression? {
        let parts = words.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
        guard !parts.isEmpty else { return nil }
        let pattern = #"(?<![\p{L}\p{N}])(?:"# + parts.joined(separator: "|") + #")(?![\p{L}\p{N}])"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: Lines

    private static func lineStarts(_ ns: NSString) -> [Int] {
        var starts = [0]
        let newline = unichar(0x0A)
        for index in 0..<ns.length where ns.character(at: index) == newline {
            starts.append(index + 1)
        }
        return starts
    }

    private static func lineIndex(of location: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static func squeeze(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
