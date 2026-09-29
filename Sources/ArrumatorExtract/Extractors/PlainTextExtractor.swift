import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// Plain text, Markdown, logs, JSON, XML, YAML and delimited tables. Reads at most `plainTextReadCapBytes`,
/// detects the encoding (see `TextEncodingDetector`) and, for CSV/TSV, keeps the header plus `csvMaxRows` rows
/// rendered as TSV.
struct PlainTextExtractor: FileExtractor {
    let name = "plain-text"
    let version = 1
    var supportedTypes: [UTType] {
        [.plainText, .commaSeparatedText, .tabSeparatedText, .delimitedText, .json, .xml, .yaml]
    }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: job.url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: config.plainTextReadCapBytes) ?? Data()
        } catch {
            throw ExtractionError.fileUnreadable(path: job.url.path, underlying: error.localizedDescription)
        }
        let truncatedRead = job.source.byteSize > Int64(data.count)
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
        if truncatedRead {
            draft.warnings.append(ExtractionWarning(.textTruncated,
                                                    "read the first \(data.count) of \(job.source.byteSize) bytes"))
        }

        if job.type.conforms(to: .delimitedText) {
            let delimiter: Character = job.type.conforms(to: .tabSeparatedText) ? "\t"
                : DelimitedText.detectDelimiter(decoded.text)
            let rows = DelimitedText.rows(decoded.text, delimiter: delimiter, maxRows: config.csvMaxRows + 1)
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
