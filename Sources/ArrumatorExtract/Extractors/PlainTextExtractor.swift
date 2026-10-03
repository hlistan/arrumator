import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// Plain text, Markdown, logs, JSON, XML, YAML and delimited tables. Reads at most `plainTextReadCapBytes`,
/// detects the encoding (see `TextEncodingDetector`) and, for CSV/TSV, keeps the header plus `csvMaxRows` rows
/// rendered as TSV, noting the rows left out.
struct PlainTextExtractor: FileExtractor {
    let name = "plain-text"
    let version = 2
    var supportedTypes: [UTType] {
        [.plainText, .commaSeparatedText, .tabSeparatedText, .delimitedText, .json, .xml, .yaml]
    }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config
        let (data, truncatedRead) = try job.head(upTo: config.plainTextReadCapBytes)
        let detector = TextEncodingDetector(candidateNames: config.candidateEncodings,
                                            sampleChars: config.languageSampleChars,
                                            cyrillicMinShare: config.cyrillicBigramMinShare)
        let decoded = detector.decode(data, truncatedRead: truncatedRead)

        var draft = ExtractionDraft(kind: .textDocument, textOrigin: .textLayer, text: decoded.text)
        draft.metadata["text:encoding"] = decoded.encodingName
        draft.metadata["text:encodingMethod"] = decoded.method.rawValue
        if decoded.isGuess {
            draft.warnings.append(ExtractionWarning(.encodingGuessed, decoded.encodingName))
        }
        if truncatedRead { draft.warnings.append(.headRead(data.count, of: job.source.byteSize)) }

        if job.type.conforms(to: .delimitedText) {
            let delimiter: Character = job.type.conforms(to: .tabSeparatedText) ? "\t"
                : DelimitedText.detectDelimiter(decoded.text)
            let (rows, cut) = DelimitedText.rows(decoded.text, delimiter: delimiter, maxRows: config.csvMaxRows + 1)
            if cut { draft.warnings.append(ExtractionWarning(.textTruncated, "kept the header and the first \(config.csvMaxRows) rows")) }
            let table = DelimitedText.tsv(rows)
            draft.kind = .spreadsheet
            draft.text = table
            draft.metadata["table:columns"] = String(rows.first?.count ?? 0)
            draft.metadata["table:rowsKept"] = String(max(0, rows.count - 1))
            draft.structure = ContentStructure(paragraphCount: rows.count,
                                               tables: [String(table.prefix(config.tableSnippetChars))])
        } else {
            draft.structure = ContentStructure(paragraphCount: TextNormalizer.nonEmptyLineCount(decoded.text))
        }
        return draft
    }
}
