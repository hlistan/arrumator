import Foundation

/// Produces safe, bounded file names, and finds a free one in a directory. The name a reading gives is made here, of
/// the labels kept and the model's title (`made`); a document that reading gave no name it can have keeps its own. No
/// document is given a name the app keeps for its own files or that its watchers never take in
/// (`SkipRules.ignoreReason(name:)`), such as a record file's.
public struct FilenameBuilder: Sendable {
    public let config: NamingConfig
    /// The names no document may have: those of the app's own files, and those the watchers ignore.
    let reserved: SkipRules
    /// Upper bound on ` (n)` suffix attempts before giving up.
    static let maxCollisionAttempts = 10_000

    public init(config: NamingConfig, reserved: SkipRules) {
        self.config = config
        self.reserved = reserved
    }

    /// Name for a filed document: the analysis's `fileName`, or else `current`, the name the document has now, its
    /// extension kept: the name it arrived with for a file in Incoming, and the name it has in the archive for one read
    /// again there, which a reading that gives no name therefore never renames. Each is cleaned (`bounded`); when
    /// nothing of either is left that is a name, the document keeps `current` as it is.
    public func name(for analysis: DocumentAnalysis, current: String, transliterate: Bool) -> String {
        let fileExtension = (current as NSString).pathExtension
        let own = (current as NSString).deletingPathExtension
        let written = [analysis.fileName, own].compactMap { $0 }.map { transliterate ? Self.transliterated($0) : $0 }
        return written.lazy.compactMap { bounded($0, fileExtension: fileExtension) }.first ?? current
    }

    /// What a free-form name becomes as a file name: cleaned (`sanitize`), cut to the character and byte limits, with
    /// `fileExtension` in lower case after it. Nil when nothing that is a name is left of it, as of one of nothing but
    /// spaces, dots and dashes, or when what is left is a name no document may have (`reserved`).
    public func bounded(_ name: String, fileExtension: String) -> String? {
        let ext = fileExtension.lowercased()
        let suffix = ext.isEmpty ? "" : "." + ext
        var base = sanitize(name)
        if base.lowercased().hasSuffix(suffix), !suffix.isEmpty { base = String(base.dropLast(suffix.count)) }
        while !fits(base + suffix), !base.isEmpty { base.removeLast() }
        base = base.trimmingCharacters(in: Self.trimmed)
        guard !base.isEmpty, reserved.ignoreReason(name: base + suffix) == nil else { return nil }
        return base + suffix
    }

    private func fits(_ s: String) -> Bool { s.count <= config.maxChars && s.utf8.count <= config.maxBytes }

    /// What a title may not begin or end with besides the separators of the name it goes into (`naming.separators`):
    /// white space, the dashes and the colon a title copied from a whole name is left with.
    static let titleEdges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:"))

    /// The name a reading makes of a document's date, its sender and its title, the parts `naming.parts` lists in its
    /// order, each followed by its separator (`naming.separators`) only when a part the document has follows it:
    /// `YYYY-MM-DD Sender - Title` by default, `YYYY-MM-DD Title` without a sender, `Sender - Title` without a date. The
    /// date is the document's `date` label, a day, and nothing else; the sender its first `sender` label, both as the
    /// user's rules keep them. A title that begins with the date or the sender, as a whole name does, does not repeat
    /// them. Nil when nothing but the date is left, which names nothing; the document then keeps its own
    /// (`name(for:current:transliterate:)`).
    public func made(date: String?, sender: String?, title: String) -> String? {
        let edges = Self.titleEdges.union(CharacterSet(charactersIn: config.separators.joined()))
        var title = title.trimmingCharacters(in: edges)
        let given = [date, sender].compactMap { $0 }.filter { !$0.isEmpty }
        // In whichever order the title writes them, each a whole word.
        while let rest = given.lazy.compactMap({ part -> String? in
            guard let range = title.range(of: part, options: [.anchored, .caseInsensitive, .diacriticInsensitive]),
                  range.upperBound == title.endIndex || !(title[range.upperBound].isLetter || title[range.upperBound].isNumber) else { return nil }
            return String(title[range.upperBound...]).trimmingCharacters(in: edges)
        }).first {
            title = rest
        }
        let values: [NamePart: String] = [.date: date ?? "", .sender: sender ?? "", .title: title]
        let present = config.parts.indices.filter { !(values[config.parts[$0]] ?? "").isEmpty }
        guard present.contains(where: { config.parts[$0] != .date }) else { return nil }
        return present.enumerated().map { n, i in
            (values[config.parts[i]] ?? "") + (n < present.count - 1 && i < config.separators.count ? config.separators[i] : "")
        }.joined()
    }

    /// What a name cut to its limits may not begin or end with.
    static let trimmed = CharacterSet(charactersIn: " .-")
    /// The character that separates the names of a path (POSIX): it never stays in a file name, whatever
    /// `naming.forbiddenCharacters` lists, so a name from the model can never reach another directory (§4.5).
    static let pathSeparator = "/"
    /// What a forbidden character becomes.
    static let replacement = "-"
    /// What a forbidden character between words becomes ("Fatura: julho"), so the dash is not glued to the word before.
    static let spacedReplacement = " - "

    /// The zero-width non-joiner and joiner: format characters, as invisible as the control characters a name loses,
    /// but part of how a word is written in Persian, in the scripts of India and in emoji, whose spelling changes
    /// without them (The Unicode Standard, ch. 23.2, "Layout Controls").
    static let joiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]

    /// NFC, path separators, forbidden and control characters replaced, no leading dots, collapsed whitespace. Of the
    /// invisible format characters, such as those that turn the direction of text, only the joiners are kept.
    public func sanitize(_ s: String) -> String {
        var out = s.precomposedStringWithCanonicalMapping
        for c in [Self.pathSeparator] + config.forbiddenCharacters {
            let escaped = NSRegularExpression.escapedPattern(for: c)
            out = out.replacingOccurrences(of: "\\s*\(escaped)\\s+|\\s+\(escaped)", with: Self.spacedReplacement, options: .regularExpression)
            out = out.replacingOccurrences(of: c, with: Self.replacement)
        }
        out = String(out.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) && !Self.joiners.contains($0) ? " " : Character($0) })
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    static func transliterated(_ s: String) -> String {
        (s.applyingTransform(.toLatin, reverse: false) ?? s).applyingTransform(.stripDiacritics, reverse: false) ?? s
    }

    /// `filename` with the collision suffix `n` (`naming.collisionFormat`) before its extension.
    private func collided(_ filename: String, _ n: Int) -> String {
        let ext = (filename as NSString).pathExtension
        return (filename as NSString).deletingPathExtension + String(format: config.collisionFormat, n) + (ext.isEmpty ? "" : "." + ext)
    }

    /// First free URL for `filename` inside `directory`, with the collision suffix before the extension when it is
    /// taken. `filename` must be one name, never a path: nothing it says can place the file anywhere but in `directory`.
    public func uniqueDestination(directory: URL, filename: String) throws -> (URL, Int?) {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains(Self.pathSeparator),
              !filename.unicodeScalars.contains("\u{0}") else { throw FileOperationError.notAFileName(filename) }
        let fm = FileManager.default
        let first = directory.appendingPathComponent(filename)
        if !fm.fileExists(atPath: first.path) { return (first, nil) }
        for n in 2...Self.maxCollisionAttempts {
            let url = directory.appendingPathComponent(collided(filename, n))
            if !fm.fileExists(atPath: url.path) { return (url, n) }
        }
        throw FileOperationError.tooManyCollisions(first.path)
    }

    /// Whether a document named `current` is already named `planned`: the same name but for case (or how its letters
    /// are composed), or for the collision suffix `uniqueDestination` gave it because the name was taken. Filing it
    /// again under `planned` where it is then moves nothing, so a document read again neither changes only the case of
    /// its name nor gains a new suffix each time, counting its own file as the one in the way.
    func isSameName(_ current: String, as planned: String) -> Bool {
        let folded = { (name: String) in name.precomposedStringWithCanonicalMapping.lowercased() }
        let (current, planned) = (folded(current), folded(planned))
        if current == planned { return true }
        let ext = (planned as NSString).pathExtension
        let (stem, plannedStem) = ((current as NSString).deletingPathExtension, (planned as NSString).deletingPathExtension)
        guard (current as NSString).pathExtension == ext, stem.hasPrefix(plannedStem) else { return false }
        let suffix = stem.dropFirst(plannedStem.count)
        guard let n = Int(String(suffix.filter { $0.isASCII && $0.isNumber })), n >= 2 else { return false }
        return folded(collided(planned, n)) == current
    }
}

/// A part of the name a reading makes (`NamingConfig.parts`).
public enum NamePart: String, Sendable, Codable, Hashable, CaseIterable {
    /// The document's `date` label, the day it was issued.
    case date
    /// Its first `sender` label.
    case sender
    /// The title the model gave it.
    case title
}
