import Foundation

/// Produces safe, bounded file names. The name is the model's; a document the model gave no name keeps its own.
public struct FilenameBuilder: Sendable {
    public let config: NamingConfig

    public init(config: NamingConfig) {
        self.config = config
    }

    /// Name for a filed document: the analysis's `fileName`, or else the name it arrived with.
    public func name(for analysis: DocumentAnalysis, source: SourceFile, transliterate: Bool) -> String {
        let chosen = analysis.fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = chosen.flatMap { $0.isEmpty ? nil : $0 } ?? source.stem
        return bounded(transliterate ? Self.transliterated(name) : name, fileExtension: source.fileExtension)
    }

    /// Sanitises a free-form name and trims it to the character and byte limits, keeping the extension.
    public func bounded(_ name: String, fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        let suffix = ext.isEmpty ? "" : "." + ext
        var base = sanitize(name)
        if base.lowercased().hasSuffix(suffix), !suffix.isEmpty { base = String(base.dropLast(suffix.count)) }
        while !fits(base + suffix), !base.isEmpty { base.removeLast() }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return (base.isEmpty ? sanitize(fileExtension) : base) + suffix
    }

    private func fits(_ s: String) -> Bool { s.count <= config.maxChars && s.utf8.count <= config.maxBytes }

    /// The character that separates the names of a path (POSIX): it never stays in a file name, whatever
    /// `naming.forbiddenCharacters` lists, so a name from the model can never reach another directory (§4.5).
    static let pathSeparator = "/"
    /// What a forbidden character becomes.
    static let replacement = "-"
    /// What a forbidden character between words becomes ("Fatura: julho"), so the dash is not glued to the word before.
    static let spacedReplacement = " - "

    /// NFC, path separators, forbidden and control characters replaced, no leading dots, collapsed whitespace.
    public func sanitize(_ s: String) -> String {
        var out = s.precomposedStringWithCanonicalMapping
        for c in [Self.pathSeparator] + config.forbiddenCharacters {
            let escaped = NSRegularExpression.escapedPattern(for: c)
            out = out.replacingOccurrences(of: "\\s*\(escaped)\\s+|\\s+\(escaped)", with: Self.spacedReplacement, options: .regularExpression)
            out = out.replacingOccurrences(of: c, with: Self.replacement)
        }
        out = String(out.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    static func transliterated(_ s: String) -> String {
        (s.applyingTransform(.toLatin, reverse: false) ?? s).applyingTransform(.stripDiacritics, reverse: false) ?? s
    }
}
