import AppKit
import PDFKit

/// Reads the text a fixture exposes without OCR, the way the app's extractors would.
enum TextProbe {
    static func pdfText(at url: URL) -> String? {
        PDFDocument(url: url)?.string
    }

    static func docxText(at url: URL) throws -> String {
        try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                               documentAttributes: nil).string
    }

    /// Text of every worksheet cell (inline strings and values) with the XML markup removed.
    static func xlsxText(at url: URL) throws -> String {
        let listing = String(decoding: try Shell.run("/usr/bin/unzip", ["-Z1", url.path]), as: UTF8.self)
        let sheets = listing.split(separator: "\n").map(String.init).filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
        return try sheets.map { sheet in
            let xml = String(decoding: try Shell.run("/usr/bin/unzip", ["-p", url.path, sheet]), as: UTF8.self)
            return xml.replacing(/<[^>]+>/, with: " ")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        }.joined(separator: "\n")
    }
}

/// Loose matching for words recovered from text layers and OCR.
enum TextMatch {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacing(/\s+/, with: " ")
    }

    /// True when `needle` occurs in `haystack` ignoring case, accents and whitespace differences.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        let text = normalize(haystack)
        let word = normalize(needle)
        return text.contains(word) || text.replacingOccurrences(of: " ", with: "").contains(word.replacingOccurrences(of: " ", with: ""))
    }

    static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.uppercased()
    }
}
