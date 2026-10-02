import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// Excel workbooks: the names of the first `maxSheets` sheets, in the workbook's order, and up to `maxSheets` × `maxRows`
/// × `maxColumns` cells rendered as TSV (shared and inline strings resolved, numbers as stored).
///
/// The parts are read with Foundation's `XMLParser`, as SpreadsheetML lays them out (ECMA-376 Part 1, §18.2 the
/// workbook, §18.3 sheets, §18.4 shared strings; Part 2 for the package's relationships): the package's
/// relationships lead to the workbook, the workbook's to its sheets and shared strings. Each part is read up to
/// `zipEntryCapBytes`, and a sheet's rows are collected as it is parsed, which stops at `maxRows`.
struct XLSXExtractor: FileExtractor {
    let name = "xlsx"
    let version = 2
    var supportedTypes: [UTType] {
        [UTType("org.openxmlformats.spreadsheetml.sheet"), UTType("org.openxmlformats.spreadsheetml.sheet.macroenabled")]
            .compactMap { $0 }
    }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config
        let zip: ZipReader
        do {
            zip = try ZipReader(url: job.url, config: config)
        } catch {
            return .metadataOnly(kind: .spreadsheet, warnings: [error.warning])
        }
        let limits = config.xlsx
        var warnings: [ExtractionWarning] = []
        var sheets: [SpreadsheetPackage.Sheet] = []
        var sheetCount = 0
        var sharedStrings: [String] = []
        do {
            let package = try SpreadsheetPackage(zip, maxSheets: limits.maxSheets)
            sheets = package.sheets
            sheetCount = package.sheetCount
            try zip.locate(sheets.map(\.path) + [package.sharedStringsPath])
            if let read = try zip.head(at: package.sharedStringsPath) {
                sharedStrings = try SharedStringsCollector.strings(read.data)
                if read.truncated {
                    warnings.append(ExtractionWarning(.textTruncated, "shared strings: read the first \(read.data.count) bytes"))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ZipReadError {
            warnings.append(error.warning)
        } catch {
            warnings.append(ExtractionWarning(.corrupted, String(describing: error)))
        }

        var sections: [String] = []
        var tables: [String] = []
        for sheet in sheets {
            try Task.checkCancellation()
            do {
                guard let read = try zip.head(at: sheet.path) else {
                    warnings.append(ExtractionWarning(.corrupted, "sheet \(sheet.name): its part \(sheet.path) is missing"))
                    continue
                }
                let parsed = try WorksheetCollector.rows(read.data, sharedStrings: sharedStrings, limits: limits)
                let tsv = DelimitedText.tsv(parsed.rows)
                sections.append("## \(sheet.name)\n\(tsv)")
                if tables.count < config.maxTables, !tsv.isEmpty {
                    tables.append(String(tsv.prefix(config.tableSnippetChars)))
                }
                if parsed.moreRows {
                    warnings.append(ExtractionWarning(.textTruncated, "sheet \(sheet.name): first \(limits.maxRows) rows"))
                } else if read.truncated {
                    warnings.append(ExtractionWarning(.textTruncated, "sheet \(sheet.name): read the first \(read.data.count) bytes"))
                } else if !parsed.wellFormed {
                    warnings.append(ExtractionWarning(.corrupted, "sheet \(sheet.name): not well-formed XML"))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ZipReadError {
                warnings.append(error.warning)
            } catch {
                warnings.append(ExtractionWarning(.corrupted, "sheet \(sheet.name): \(error)"))
            }
        }
        if sheetCount > sheets.count {
            warnings.append(ExtractionWarning(.textTruncated, "first \(sheets.count) of \(sheetCount) sheets"))
        }
        let text = sections.joined(separator: "\n\n")
        var draft = ExtractionDraft(kind: .spreadsheet, textOrigin: text.isEmpty ? .none : .textLayer, text: text)
        draft.structure = ContentStructure(paragraphCount: 0, tables: tables, sheetNames: sheets.map(\.name))
        let core = OOXMLCoreProperties.metadata(in: zip, prefix: "doc")
        draft.metadata = core.metadata
        draft.warnings = warnings + core.warnings
        return draft
    }
}
