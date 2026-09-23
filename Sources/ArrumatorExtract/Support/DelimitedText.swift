import Foundation

/// RFC 4180 CSV/TSV parsing (quoted fields, doubled quotes, line breaks inside quotes) with delimiter detection.
enum DelimitedText {
    /// Delimiters tried when the type does not fix one; the most frequent outside quotes on the first line wins.
    private static let candidates: [Character] = [",", ";", "\t", "|"]

    static func detectDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [:]
        var quoted = false
        for char in text {
            if char == "\"" { quoted.toggle() }
            if char == "\n", !quoted { break }
            if !quoted, candidates.contains(char) { counts[char, default: 0] += 1 }
        }
        return candidates.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ","
    }

    /// The first `maxRows` records (header included).
    static func rows(_ text: String, delimiter: Character, maxRows: Int) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending = iterator.next()
        while let char = pending, rows.count < maxRows {
            pending = iterator.next()
            if quoted {
                if char == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = iterator.next()
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"" where field.isEmpty:
                quoted = true
            case delimiter:
                row.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                row.append(field)
                field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            default:
                field.append(char)
            }
        }
        if rows.count < maxRows, !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// Rows rendered as TSV (tabs and line breaks inside cells flattened to spaces).
    static func tsv(_ rows: [[String]]) -> String {
        rows.map { cells in
            cells.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }
        .joined(separator: "\n")
    }
}
