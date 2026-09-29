import Foundation

struct Workbook: Sendable {
    let title: String
    let creator: String
    let created: Day
    let sheets: [Sheet]
}

struct Sheet: Sendable {
    let name: String
    /// Column widths in Excel character units.
    let columnWidths: [Double]
    let rows: [[Cell]]
}

enum Cell: Sendable {
    case empty
    case text(String, bold: Bool = false)
    case integer(Int)
    case money(Money, bold: Bool = false)
    case percent(Int)
    /// A formula with its cached result, so readers that do not calculate (CoreXLSX) still see the value.
    case formula(String, cached: Money, bold: Bool = false)
}

/// Minimal SpreadsheetML package written by hand: content types, relationships, core properties, styles and
/// one worksheet per sheet with inline strings (no shared-string table).
struct XLSXRenderer {
    let settings: RenderSettings

    func render(_ workbook: Workbook) throws -> Data {
        var entries: [(path: String, data: Data)] = [
            ("[Content_Types].xml", contentTypes(sheetCount: workbook.sheets.count)),
            ("_rels/.rels", xml("""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
                <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
                </Relationships>
                """)),
            ("docProps/core.xml", coreProperties(workbook)),
            ("xl/workbook.xml", workbookPart(workbook)),
            ("xl/_rels/workbook.xml.rels", workbookRelationships(sheetCount: workbook.sheets.count)),
            ("xl/styles.xml", styles),
        ]
        for (index, sheet) in workbook.sheets.enumerated() {
            entries.append(("xl/worksheets/sheet\(index + 1).xml", worksheet(sheet)))
        }
        return try ZipArchive(settings: settings).archive(entries)
    }

    private func xml(_ body: String) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + body).utf8)
    }

    private func contentTypes(sheetCount: Int) -> Data {
        let sheets = (1...sheetCount).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return xml("""
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
            \(sheets)</Types>
            """)
    }

    private func coreProperties(_ workbook: Workbook) -> Data {
        let stamp = "\(workbook.created.iso)T\(String(format: "%02d", settings.pdf.metadataHour)):00:00Z"
        return xml("""
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
            <dc:title>\(escape(workbook.title))</dc:title><dc:creator>\(escape(workbook.creator))</dc:creator>\
            <dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created>\
            <dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified>\
            </cp:coreProperties>
            """)
    }

    private func workbookPart(_ workbook: Workbook) -> Data {
        let sheets = workbook.sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(escape(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return xml("""
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets>\(sheets)</sheets></workbook>
            """)
    }

    private func workbookRelationships(sheetCount: Int) -> Data {
        let sheets = (1...sheetCount).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
        }.joined()
        return xml("""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(sheets)<Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
            </Relationships>
            """)
    }

    /// Style indices used by `Cell`: 0 plain, 1 bold, 2 money, 3 bold money, 4 percent.
    private var styles: Data {
        xml("""
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="5">\
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
            <xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
            <xf numFmtId="4" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>\
            <xf numFmtId="9" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
            </cellXfs></styleSheet>
            """)
    }

    private func worksheet(_ sheet: Sheet) -> Data {
        let columns = sheet.columnWidths.enumerated().map { index, width in
            "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }.joined()
        let rows = sheet.rows.enumerated().map { rowIndex, cells in
            let number = rowIndex + 1
            let content = cells.enumerated().compactMap { columnIndex, cell in
                self.cell(cell, reference: "\(columnName(columnIndex))\(number)")
            }.joined()
            return "<row r=\"\(number)\">\(content)</row>"
        }.joined()
        return xml("""
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <cols>\(columns)</cols><sheetData>\(rows)</sheetData></worksheet>
            """)
    }

    private func cell(_ cell: Cell, reference: String) -> String? {
        switch cell {
        case .empty:
            return nil
        case .text(let text, let bold):
            return "<c r=\"\(reference)\" t=\"inlineStr\"\(bold ? " s=\"1\"" : "")><is><t xml:space=\"preserve\">\(escape(text))</t></is></c>"
        case .integer(let value):
            return "<c r=\"\(reference)\"><v>\(value)</v></c>"
        case .money(let amount, let bold):
            return "<c r=\"\(reference)\" s=\"\(bold ? 3 : 2)\"><v>\(amount.decimal)</v></c>"
        case .percent(let value):
            return "<c r=\"\(reference)\" s=\"4\"><v>\(Double(value) / 100)</v></c>"
        case .formula(let formula, let cached, let bold):
            return "<c r=\"\(reference)\" s=\"\(bold ? 3 : 2)\"><f>\(escape(formula))</f><v>\(cached.decimal)</v></c>"
        }
    }

    private func columnName(_ index: Int) -> String {
        precondition(index < 26, "fixtures use at most 26 columns")
        return String(UnicodeScalar(UInt8(65 + index)))
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
