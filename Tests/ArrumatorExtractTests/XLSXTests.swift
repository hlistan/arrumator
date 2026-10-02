import ArrumatorCore
@testable import ArrumatorExtract
import Foundation
import Testing

@Suite("Excel workbooks, as Excel writes them")
struct XLSXTests {
    private let registry: ExtractorRegistry

    init() throws { registry = try TestConfig.registry() }

    private func extract(_ files: [String: String], _ name: String = "faturas.xlsx") async throws -> ExtractedContent {
        let url = try Scratch().writeZip(name, files: files)
        return try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
    }

    @Test("Each kind of cell Excel writes is read as the text it shows or stores")
    func cells() async throws {
        let content = try await extract(ExcelWorkbook.files())
        let lines = content.text.components(separatedBy: "\n")
        let cells = lines.map { $0.components(separatedBy: "\t") }
        try #require(cells.count == 9, "the two sheets' rows, each sheet under its name: \(lines)")
        #expect(cells[1] == ["Fornecedor", "EDP Comercial", "東京", "A & B <c>"],
                "shared strings: plain, rich runs joined, a phonetic reading left out, character references decoded")
        #expect(cells[2][0] == "45123", "a date is its serial number, as stored")
        #expect(cells[2][1] == "45.9", "a number as stored")
        #expect(cells[2][2] == "1", "a boolean as stored")
        #expect(cells[2][3] == "#DIV/0!", "an error by its code, not its formula")
        #expect(cells[2][4].isEmpty, "a cell with a style and no value is empty")
        #expect(cells[2][5] == "91.8", "a formula's cached value, not the formula")
        #expect(cells[2][6] == "xy", "a formula's cached string")
        #expect(cells[2][7] == "inline", "an inline string of rich runs, joined")
        #expect(cells[3] == ["", "45.9", "91.8", "linha 1 linha 2"],
                "a shared formula's cached value, and a string's line break flattened, each in its column")
        #expect(cells[4] == ["", "", "0"], "an empty shared string adds nothing")
        #expect(cells[5] == ["", "-1.5E-3"], "a row further down follows the rows before it")
        #expect(content.structure?.sheetNames == ["Faturas", "Resumo"], "sheets in the workbook's order")
        #expect(content.metadata["doc:title"] == "Faturas", "the core properties are read")
        #expect(content.warnings.isEmpty, "a workbook as Excel writes it is read without warnings: \(content.warningSummary)")
    }

    @Test("The same workbook reads the same however its package is laid out", arguments: ExcelWorkbook.Layout.allCases)
    func layouts(_ layout: ExcelWorkbook.Layout) async throws {
        let content = try await extract(ExcelWorkbook.files(layout))
        #expect(content.text == ExcelWorkbook.text, "\(layout): \(layout.why)")
        #expect(content.warnings.isEmpty, "\(layout): \(content.warningSummary)")
    }

    @Test("A cell written without its reference follows the cell before it")
    func cellsWithoutReferences() async throws {
        var files = ExcelWorkbook.files()
        files["xl/worksheets/sheet2.xml"] = ExcelWorkbook.sheet(
            #"<row><c t="s"><v>0</v></c><c><v>7</v></c><c t="inlineStr"><is><t>z</t></is></c></row>"#)
        let content = try await extract(files)
        #expect(content.text.hasSuffix("## Resumo\nFornecedor\t7\tz"), "each cell in the column after the one before it")
    }

    @Test("A sheet whose relationship points outside the package is not read as a part of it")
    func externalTarget() async throws {
        var files = ExcelWorkbook.files()
        files["xl/_rels/workbook.xml.rels"] = ExcelWorkbook.workbookRelationships(
            sheets: [("rId1", "worksheets/sheet1.xml", nil), ("rId2", "worksheets/sheet2.xml", "External")])
        let content = try await extract(files)
        #expect(content.structure?.sheetNames == ["Faturas"], "a target outside the package is no sheet of the workbook")
        #expect(!content.text.contains("## Resumo"), "and no part of the package is read in its place")
    }

    @Test("A workbook named by many relationships, of more sheets than maxSheets, is read once and its sheets counted",
          .timeLimit(.minutes(1)))
    func manySheets() async throws {
        var files = ExcelWorkbook.files()
        let main = (1...200).map { #"<Relationship Id="rId\#($0)" Type="\#(ExcelWorkbook.relationships(false))/officeDocument" Target="xl/workbook.xml"/>"# }
        files["_rels/.rels"] = ExcelWorkbook.declaration
            + #"<Relationships xmlns="\#(ExcelWorkbook.packageRelationshipsNamespace)">\#(main.joined())</Relationships>"#
        let sheets = (1...100_000).map { #"<sheet name="S\#($0)" sheetId="\#($0)" r:id="rId1"/>"# }
        files["xl/workbook.xml"] = ExcelWorkbook.declaration + #"<workbook xmlns="\#(ExcelWorkbook.main(false))" "#
            + #"xmlns:r="\#(ExcelWorkbook.relationships(false))"><sheets>\#(sheets.joined())</sheets></workbook>"#
        let content = try await extract(files)
        let maxSheets = try TestConfig.pipeline().extraction.xlsx.maxSheets
        #expect(content.structure?.sheetNames == (1...maxSheets).map { "S\($0)" },
                "the workbook is read once, for its first maxSheets sheets")
        #expect(content.warnings.map(\.detail) == ["first \(maxSheets) of 100000 sheets"], "and the rest are counted")
    }

    @Test("Shared strings no relationship names are read where Excel puts them")
    func sharedStringsWithoutRelationship() async throws {
        var files = ExcelWorkbook.files()
        files["xl/_rels/workbook.xml.rels"] = ExcelWorkbook.workbookRelationships(
            sheets: [("rId1", "worksheets/sheet1.xml", nil), ("rId2", "worksheets/sheet2.xml", nil)], sharedStrings: nil)
        let content = try await extract(files)
        #expect(content.text == ExcelWorkbook.text, "every string cell keeps its text, as CoreXLSX read it")
    }
}

/// A workbook of two sheets written as Excel writes one: its markup-compatibility namespaces, a theme, styles,
/// defined names, rich and phonetic shared strings, and each kind of cell (ECMA-376 Part 1, §18).
enum ExcelWorkbook {
    /// Ways to lay out the same workbook that a reader must follow to the same parts.
    enum Layout: String, CaseIterable, Sendable {
        case transitional, strict, absoluteTargets, otherFolders, relationshipsReordered

        var why: String {
            switch self {
            case .transitional: "as Excel saves it"
            case .strict: "in the Strict namespaces (ECMA-376 Part 1 §8.1), whose relationship types end as the others do"
            case .absoluteTargets: "with targets from the package's root"
            case .otherFolders: "with sheets in a folder below the workbook's and in one beside it, reached by `..`"
            case .relationshipsReordered: "with the sheets' relationships in the other order than the sheets"
            }
        }
    }

    /// What `files()` reads as, in any layout.
    static let text = """
        ## Faturas
        Fornecedor\tEDP Comercial\t東京\tA & B <c>
        45123\t45.9\t1\t#DIV/0!\t\t91.8\txy\tinline
        \t45.9\t91.8\tlinha 1 linha 2
        \t\t0
        \t-1.5E-3

        ## Resumo
        Fornecedor\t7
        """

    static func files(_ layout: Layout = .transitional) -> [String: String] {
        let strict = layout == .strict
        let workbookTarget = layout == .absoluteTargets ? "/xl/workbook.xml" : "xl/workbook.xml"
        var files = [
            "[Content_Types].xml": contentTypes,
            "_rels/.rels": packageRelationships(strict: strict, workbook: workbookTarget),
            "xl/workbook.xml": workbook(strict: strict),
            "xl/_rels/workbook.xml.rels": workbookRelationships(
                sheets: [("rId1", "worksheets/sheet1.xml", nil), ("rId2", "worksheets/sheet2.xml", nil)], strict: strict),
            "xl/sharedStrings.xml": sharedStrings(strict: strict),
            "xl/worksheets/sheet1.xml": sheet(firstSheetRows, strict: strict),
            "xl/worksheets/sheet2.xml": sheet(
                #"<row r="1" spans="1:2"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>7</v></c></row>"#, strict: strict),
            "xl/styles.xml": declaration + #"<styleSheet xmlns="\#(main(strict))"/>"#,
            "xl/theme/theme1.xml": declaration
                + #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"/>"#,
            "docProps/core.xml": coreProperties,
            "docProps/app.xml": declaration
                + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">"#
                + "<Application>Microsoft Excel</Application></Properties>",
        ]
        switch layout {
        case .transitional, .strict:
            break
        case .absoluteTargets:
            files["xl/_rels/workbook.xml.rels"] = workbookRelationships(
                sheets: [("rId1", "/xl/worksheets/sheet1.xml", nil), ("rId2", "/xl/worksheets/sheet2.xml", nil)],
                sharedStrings: "/xl/sharedStrings.xml")
        case .otherFolders:
            files["xl/_rels/workbook.xml.rels"] = workbookRelationships(
                sheets: [("rId1", "data/one.xml", nil), ("rId2", "../other/two.xml", nil)])
            files["xl/data/one.xml"] = files.removeValue(forKey: "xl/worksheets/sheet1.xml")
            files["other/two.xml"] = files.removeValue(forKey: "xl/worksheets/sheet2.xml")
        case .relationshipsReordered:
            files["xl/_rels/workbook.xml.rels"] = workbookRelationships(
                sheets: [("rId2", "worksheets/sheet2.xml", nil), ("rId1", "worksheets/sheet1.xml", nil)])
        }
        return files
    }

    static let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

    /// The SpreadsheetML namespace, transitional or strict.
    static func main(_ strict: Bool) -> String {
        strict ? "http://purl.oclc.org/ooxml/spreadsheetml/main" : "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    }

    /// The namespace of office document relationships and their types, transitional or strict.
    static func relationships(_ strict: Bool) -> String {
        strict ? "http://purl.oclc.org/ooxml/officeDocument/relationships"
            : "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    }

    static let packageRelationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"

    static func packageRelationships(strict: Bool, workbook: String) -> String {
        let types = relationships(strict)
        return """
            \(declaration)
            <Relationships xmlns="\(packageRelationshipsNamespace)">\
            <Relationship Id="rId3" Type="\(types)/extended-properties" Target="docProps/app.xml"/>\
            <Relationship Id="rId2" Type="\(packageRelationshipsNamespace)/metadata/core-properties" \
            Target="docProps/core.xml"/>\
            <Relationship Id="rId1" Type="\(types)/officeDocument" Target="\(workbook)"/>\
            </Relationships>
            """
    }

    /// The workbook's relationships: a theme, styles, `sheets` (id, target and target mode) and the shared strings.
    static func workbookRelationships(sheets: [(id: String, target: String, mode: String?)], strict: Bool = false,
                                      sharedStrings: String? = "sharedStrings.xml") -> String {
        let types = relationships(strict)
        let sheetRelationships = sheets.map { sheet -> String in
            let mode = sheet.mode.map { #" TargetMode="\#($0)""# } ?? ""
            return #"<Relationship Id="\#(sheet.id)" Type="\#(types)/worksheet" Target="\#(sheet.target)"\#(mode)/>"#
        }.joined()
        let strings = sharedStrings.map { #"<Relationship Id="rId9" Type="\#(types)/sharedStrings" Target="\#($0)"/>"# } ?? ""
        return """
            \(declaration)
            <Relationships xmlns="\(packageRelationshipsNamespace)">\
            <Relationship Id="rId7" Type="\(types)/theme" Target="theme/theme1.xml"/>\
            <Relationship Id="rId8" Type="\(types)/styles" Target="styles.xml"/>\
            \(sheetRelationships)\(strings)</Relationships>
            """
    }

    static func workbook(strict: Bool) -> String {
        """
        \(declaration)
        <workbook xmlns="\(main(strict))" xmlns:r="\(relationships(strict))" \
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="x15 xr xr6 xr10 xr2" \
        xmlns:x15="http://schemas.microsoft.com/office/spreadsheetml/2010/11/main" \
        xmlns:xr="http://schemas.microsoft.com/office/spreadsheetml/2014/revision" \
        xmlns:xr6="http://schemas.microsoft.com/office/spreadsheetml/2016/revision6" \
        xmlns:xr10="http://schemas.microsoft.com/office/spreadsheetml/2016/revision10" \
        xmlns:xr2="http://schemas.microsoft.com/office/spreadsheetml/2015/revision2">\
        <fileVersion appName="xl" lastEdited="7" lowestEdited="7" rupBuild="27425"/>\
        <workbookPr defaultThemeVersion="202300"/>\
        <xr:revisionPtr revIDLastSave="0" documentId="8_{0}" xr6:coauthVersionLast="47" xr6:coauthVersionMax="47" \
        xr10:uidLastSave="{00000000-0000-0000-0000-000000000000}"/>\
        <bookViews><workbookView xWindow="-120" yWindow="-120" windowWidth="29040" windowHeight="15720" \
        xr2:uid="{1}"/></bookViews>\
        <sheets><sheet name="Faturas" sheetId="1" r:id="rId1"/><sheet name="Resumo" sheetId="2" r:id="rId2"/></sheets>\
        <definedNames><definedName name="_xlnm.Print_Area" localSheetId="0">Faturas!$A$1:$E$10</definedName>\
        </definedNames><calcPr calcId="191029"/></workbook>
        """
    }

    /// Plain, rich, phonetic, escaped, multi-line and empty strings.
    static func sharedStrings(strict: Bool) -> String {
        let style = #"<sz val="11"/><color theme="1"/><rFont val="Calibri"/><family val="2"/><scheme val="minor"/>"#
        return """
            \(declaration)
            <sst xmlns="\(main(strict))" count="8" uniqueCount="6"><si><t>Fornecedor</t></si>\
            <si><r><rPr><b/>\(style)</rPr><t>EDP</t></r>\
            <r><rPr>\(style)</rPr><t xml:space="preserve"> Comercial</t></r></si>\
            <si><t>東京</t><rPh sb="0" eb="2"><t>トウキョウ</t></rPh><phoneticPr fontId="1"/></si>\
            <si><t>A &amp; B &lt;c&gt;</t></si>\
            <si><t xml:space="preserve">linha 1
            linha 2 </t></si>\
            <si><t/></si></sst>
            """
    }

    /// A date, a number, a boolean, an error, a styled empty cell, formulas with cached values and an inline string of
    /// rich runs; a shared formula; an empty string; a row further down.
    static let firstSheetRows = """
        <row r="1" spans="1:8" x14ac:dyDescent="0.25"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c>\
        <c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row>\
        <row r="2" spans="1:8"><c r="A2" s="1"><v>45123</v></c><c r="B2" s="2"><v>45.9</v></c>\
        <c r="C2" t="b"><v>1</v></c><c r="D2" t="e"><f>1/0</f><v>#DIV/0!</v></c><c r="E2" s="3"/>\
        <c r="F2"><f>SUM(B2:B3)</f><v>91.8</v></c><c r="G2" t="str"><f>"x"&amp;"y"</f><v>xy</v></c>\
        <c r="H2" t="inlineStr"><is><r><t>in</t></r><r><rPr><b/></rPr><t>line</t></r></is></c></row>\
        <row r="3" spans="1:8"><c r="B3"><v>45.9</v></c><c r="C3"><f t="shared" ref="C3:C4" si="0">B3*2</f>\
        <v>91.8</v></c><c r="D3" t="s"><v>4</v></c></row>\
        <row r="4" spans="1:8" ht="15"><c r="C4"><f t="shared" si="0"/><v>0</v></c><c r="E4" t="s"><v>5</v></c></row>\
        <row r="10" spans="1:8"><c r="B10"><v>-1.5E-3</v></c></row>
        """

    static func sheet(_ rows: String, strict: Bool = false) -> String {
        """
        \(declaration)
        <worksheet xmlns="\(main(strict))" xmlns:r="\(relationships(strict))" \
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="x14ac xr xr2 xr3" \
        xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac" \
        xmlns:xr="http://schemas.microsoft.com/office/spreadsheetml/2014/revision" xr:uid="{2}">\
        <dimension ref="A1:H10"/><sheetViews><sheetView tabSelected="1" workbookViewId="0">\
        <selection activeCell="B2" sqref="B2"/></sheetView></sheetViews>\
        <sheetFormatPr defaultRowHeight="15" x14ac:dyDescent="0.25"/>\
        <cols><col min="1" max="1" width="20" customWidth="1"/></cols>\
        <sheetData>\(rows)</sheetData>\
        <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>\
        <pageSetup paperSize="9" orientation="portrait" r:id="rId1"/></worksheet>
        """
    }

    static let contentTypes = """
        \(declaration)
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>
        """

    static let coreProperties = """
        \(declaration)
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>Faturas</dc:title><dc:creator>Maria</dc:creator></cp:coreProperties>
        """
}
