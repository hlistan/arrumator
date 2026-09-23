import ArrumatorCore
import CoreXLSX
import Foundation
import UniformTypeIdentifiers

/// Excel workbooks through CoreXLSX: every sheet name, and up to `maxSheets` × `maxRows` × `maxColumns` cells
/// rendered as TSV (shared and inline strings resolved, numbers as stored).
struct XLSXExtractor: FileExtractor {
    let name = "xlsx"
    let version = 1
    var supportedTypes: [UTType] {
        [UTType("org.openxmlformats.spreadsheetml.sheet"), UTType("org.openxmlformats.spreadsheetml.sheet.macroenabled")]
            .compactMap { $0 }
    }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let limits = job.config.xlsx
        guard let file = XLSXFile(filepath: job.url.path) else {
            return .metadataOnly(kind: .spreadsheet, warnings: [ExtractionWarning(.corrupted, "not a ZIP package")])
        }
        var sheetNames: [String] = []
        var sections: [String] = []
        var tables: [String] = []
        var warnings: [ExtractionWarning] = []
        do {
            let sharedStrings = try file.parseSharedStrings()
            for workbook in try file.parseWorkbooks() {
                for (index, sheet) in try file.parseWorksheetPathsAndNames(workbook: workbook).enumerated() {
                    let sheetName = sheet.name ?? "Sheet \(index + 1)"
                    sheetNames.append(sheetName)
                    guard sections.count < limits.maxSheets else { continue }
                    try Task.checkCancellation()
                    let worksheet = try file.parseWorksheet(at: sheet.path)
                    let rows = Self.rows(worksheet, sharedStrings: sharedStrings, limits: limits)
                    let tsv = DelimitedText.tsv(rows)
                    sections.append("## \(sheetName)\n\(tsv)")
                    if tables.count < job.config.maxTables, !tsv.isEmpty {
                        tables.append(String(tsv.prefix(job.config.tableSnippetChars)))
                    }
                    if (worksheet.data?.rows.count ?? 0) > limits.maxRows {
                        warnings.append(ExtractionWarning(.textTruncated, "sheet \(sheetName): first \(limits.maxRows) rows"))
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append(ExtractionWarning(.corrupted, String(describing: error)))
        }
        if sheetNames.count > limits.maxSheets {
            warnings.append(ExtractionWarning(.textTruncated, "first \(limits.maxSheets) of \(sheetNames.count) sheets"))
        }
        let text = sections.joined(separator: "\n\n")
        var draft = ExtractionDraft(kind: .spreadsheet, textOrigin: text.isEmpty ? .none : .textLayer, text: text)
        draft.structure = ContentStructure(paragraphCount: 0, tables: tables, sheetNames: sheetNames)
        draft.metadata = OOXMLCoreProperties.metadata(of: job.url, entryCap: job.config.zipEntryCapBytes, prefix: "doc")
        draft.warnings = warnings
        return draft
    }

    private static func rows(_ worksheet: Worksheet, sharedStrings: SharedStrings?,
                             limits: ExtractionConfig.XLSX) -> [[String]] {
        guard let first = ColumnReference("A") else { return [] }
        return (worksheet.data?.rows ?? []).prefix(limits.maxRows).compactMap { row in
            var cells: [String] = []
            for cell in row.cells {
                let column = first.distance(to: cell.reference.column)
                guard column >= 0, column < limits.maxColumns else { continue }
                let value = text(of: cell, sharedStrings: sharedStrings)
                if cells.count <= column { cells += [String](repeating: "", count: column + 1 - cells.count) }
                cells[column] = value
            }
            return cells.allSatisfy(\.isEmpty) ? nil : cells
        }
    }

    /// Cell text; shared-string indices are bounds-checked because they come from the file.
    private static func text(of cell: Cell, sharedStrings: SharedStrings?) -> String {
        if cell.type == .sharedString {
            guard let sharedStrings, let index = cell.value.flatMap(Int.init),
                  sharedStrings.items.indices.contains(index) else { return "" }
            let item = sharedStrings.items[index]
            return item.text ?? item.richText.compactMap(\.text).joined()
        }
        return cell.inlineString?.text ?? cell.value ?? ""
    }
}
