import ArrumatorCore
@testable import ArrumatorExtract
import Foundation
import Testing

@Suite("Office documents, e-mail and archives")
struct OfficeAndMailTests {
    private let registry: ExtractorRegistry

    init() throws { registry = try TestConfig.registry() }

    @Test("docx through textutil, with core properties")
    func docx() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeDocx("contrato.docx", text: """
        Contrato de arrendamento
        Data: 1 de março de 2025
        Senhorio: Maria Santos, NIF 999999990
        Renda mensal: 850,00 €
        """, title: "Contrato de arrendamento", author: "Maria Santos")
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.extractorName == "textutil", "a .docx is read by textutil")
        #expect(content.kind == .textDocument, "a .docx is a text document")
        #expect(content.textOrigin == .textLayer, "a .docx's text is its own, with no OCR")
        #expect(content.text.contains("Contrato de arrendamento"), "the first paragraph is read")
        #expect(content.text.contains("Renda mensal"), "the last paragraph is read too")
        #expect(content.metadata["doc:title"] == "Contrato de arrendamento", "the core-properties title is kept as metadata")
        #expect(content.metadata["doc:creator"] == "Maria Santos", "the core-properties author is kept as metadata")
        #expect(content.entities.documentDate?.date == "2025-03-01", "a Portuguese date written in words dates the contract")
        #expect(content.language.primary == "pt", "a Portuguese contract is detected as Portuguese")
        #expect(content.warnings.map(\.code) == [], "a well-formed .docx is read without warnings")
    }

    @Test("textutil is told not to load what an HTML page or web archive refers to")
    func textutilArguments() throws {
        let page = try Scratch().url("page.html")
        // `-noload`: "Do not load subsidiary resources" (man textutil), so reading a page never reaches the network
        // (AGENTS.md §4.1) whatever textutil does by default.
        #expect(TextutilExtractor.arguments(for: page) == ["-convert", "txt", "-noload", "-encoding", "UTF-8", "-stdout", page.path],
                "textutil converts to UTF-8 text on standard output without loading images, style sheets or frames")
    }

    @Test("xlsx: sheet names, shared and inline strings as TSV, limits")
    func xlsx() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeZip("contas.xlsx", files: XLSXFixture.files)
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.extractorName == "xlsx", "a .xlsx is read by the built-in reader")
        #expect(content.kind == .spreadsheet, "a .xlsx is a spreadsheet")
        #expect(content.structure?.sheetNames == ["Faturas", "Resumo"], "sheet names come in workbook order")
        #expect(content.text.contains("## Faturas"), "each sheet starts with its name as a heading")
        #expect(content.text.contains("Fornecedor\tValor"), "shared strings are resolved, cells separated by tabs")
        #expect(content.text.contains("EDP Comercial\t45.9"), "numbers are kept as stored")
        #expect(content.text.contains("Galp\t\tinline note"), "an empty cell keeps its column, and inline strings are read")
        #expect(content.structure?.tables.count == 2, "each sheet is one table")

        let limited = try TestConfig.context { extraction, _ in
            extraction.xlsx.maxSheets = 1
            extraction.xlsx.maxRows = 2
        }
        let capped = try await registry.extract(url, sha256: "x", context: limited, trace: .disabled)
        #expect(!capped.text.contains("Galp"), "rows past maxRows are left out")
        #expect(!capped.text.contains("## Resumo"), "sheets past maxSheets are left out")
        #expect(capped.structure?.sheetNames == ["Faturas"], "only the sheets read are listed; the rest are counted")
        #expect(capped.warnings.map(\.detail) == ["sheet Faturas: first 2 rows", "first 1 of 2 sheets"],
                "what was cut is noted, so the model knows it saw part of the workbook")
    }

    @Test("xlsx whose XML trapped CoreXLSX is read: two sheets of one relationship, a column of 14 letters, an empty target")
    func hostileWorkbooks() async throws {
        let scratch = try Scratch()
        let sameRelationship = XLSXFixture.files(replacing: "xl/workbook.xml", with: XLSXFixture.workbook(
            #"<sheet name="Faturas" sheetId="1" r:id="rId1"/><sheet name="Cópia" sheetId="2" r:id="rId1"/>"#))
        let url = try scratch.writeZip("same.xlsx", files: sameRelationship)
        let same = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(same.structure?.sheetNames == ["Faturas", "Cópia"], "both sheets are listed, each by its name")
        #expect(same.text.contains("EDP Comercial\t45.9"), "and the part they share is read")

        let longColumn = XLSXFixture.files(replacing: "xl/worksheets/sheet2.xml", with: XLSXFixture.worksheet(
            #"<row r="1"><c r="AAAAAAAAAAAAAA1"><v>1</v></c><c r="A1" t="s"><v>4</v></c></row>"#))
        let wide = try await registry.extract(try scratch.writeZip("wide.xlsx", files: longColumn), sha256: "x",
                                              context: try TestConfig.context(), trace: .disabled)
        #expect(wide.text.contains("## Resumo\nTotal"), "a cell past every column is left out, and the row's other cells are read")

        let emptyTarget = XLSXFixture.files(replacing: "_rels/.rels", with: XLSXFixture.packageRelationships(target: ""))
        let empty = try await registry.extract(try scratch.writeZip("empty.xlsx", files: emptyTarget), sha256: "x",
                                               context: try TestConfig.context(), trace: .disabled)
        #expect(empty.warnings.map(\.detail).first == SpreadsheetError.noWorkbook.description,
                "a package whose workbook cannot be found is noted as corrupted (\(empty.warningSummary))")
    }

    @Test("xlsx sheet larger than zipEntryCapBytes is read up to the cap, and its rows stop at maxRows while parsed")
    func largeSheet() async throws {
        let scratch = try Scratch()
        let rows = (1...2_000).map { #"<row r="\#($0)"><c r="A\#($0)" t="inlineStr"><is><t>Linha \#($0)</t></is></c></row>"# }
        let files = XLSXFixture.files(replacing: "xl/worksheets/sheet1.xml", with: XLSXFixture.worksheet(rows.joined()))
        let url = try scratch.writeZip("large.xlsx", files: files)
        let cap = 16_384
        let capped = try await registry.extract(url, sha256: "x", context: try TestConfig.context { extraction, _ in
            extraction.zipEntryCapBytes = cap
            extraction.xlsx.maxRows = 5_000
        }, trace: .disabled)
        #expect(capped.text.contains("Linha 1\n"), "the first rows of the sheet are read")
        #expect(!capped.text.contains("Linha 2000"), "nothing past the cap is unpacked")
        #expect(capped.warnings.map(\.detail).contains("sheet Faturas: read the first \(cap) bytes"),
                "the cut is noted (\(capped.warningSummary))")

        // A shared string table past the cap: its first strings are read, and a cell that names a later one is empty.
        let strings = (0..<2_000).map { "<si><t>Texto \($0)</t></si>" }.joined()
        var shared = XLSXFixture.files(replacing: "xl/sharedStrings.xml", with: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\(strings)</sst>
            """)
        shared["xl/worksheets/sheet1.xml"] = XLSXFixture.worksheet(#"<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1999</v></c></row>"#)
        let strung = try await registry.extract(try scratch.writeZip("strings.xlsx", files: shared), sha256: "x",
                                                context: try TestConfig.context { extraction, _ in extraction.zipEntryCapBytes = cap },
                                                trace: .disabled)
        #expect(strung.text.contains("## Faturas\nTexto 0\n"), "a string within the cap is read, one past it left empty")
        #expect(strung.warnings.map(\.detail).contains("shared strings: read the first \(cap) bytes"),
                "the cut is noted (\(strung.warningSummary))")

        // Past the rows wanted, the XML breaks off: a reader that stops at maxRows never reaches it.
        let broken = XLSXFixture.files(replacing: "xl/worksheets/sheet1.xml",
                                       with: XLSXFixture.worksheet(rows.prefix(3).joined() + #"<row r="4"><c r="A4"><v>4</v></row>"#))
        let stopped = try await registry.extract(try scratch.writeZip("broken.xlsx", files: broken), sha256: "x",
                                                 context: try TestConfig.context { extraction, _ in extraction.xlsx.maxRows = 3 },
                                                 trace: .disabled)
        #expect(stopped.text.contains("Linha 3"), "the rows wanted are read")
        #expect(stopped.warnings.map(\.detail) == ["sheet Faturas: first 3 rows"],
                "only the row limit is noted: parsing stopped before the broken XML (\(stopped.warningSummary))")
    }

    @Test("pptx: slides in numeric order, then notes")
    func pptx() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeZip("deck.pptx", files: PPTXFixture.files)
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.extractorName == "pptx", "a .pptx is read by the built-in reader")
        #expect(content.kind == .presentation, "a .pptx is a presentation")
        #expect(content.structure?.slideCount == 3, "notes slides are not counted as slides")
        let text = content.text
        let first = try #require(text.range(of: "Quarterly review"))
        let second = try #require(text.range(of: "Second slide"))
        let tenth = try #require(text.range(of: "Tenth slide"))
        let notes = try #require(text.range(of: "Speaker note one"))
        #expect(first.lowerBound < second.lowerBound, "slide 1 comes before slide 2")
        #expect(second.lowerBound < tenth.lowerBound, "slides are ordered by number, so slide10 comes after slide2")
        #expect(tenth.lowerBound < notes.lowerBound, "speaker notes come after every slide")
        #expect(text.contains("Quarterly review\nRevenue up"), "runs join into one line, and each paragraph is a line")
    }

    @Test("eml: RFC 2047 subject, KOI8-R quoted-printable body, RFC 2231 attachment name")
    func eml() async throws {
        let scratch = try Scratch()
        let url = try scratch.write("mail.eml", data: try EMLFixture.message())
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.kind == .email, "an .eml is an e-mail")
        #expect(content.metadata[MetadataKey.emailSubject] == "Fatura nº 123 — EDP от 15 мая", "a folded subject of RFC 2047 words is decoded and joined")
        #expect(content.metadata[MetadataKey.emailFrom] == "ПАО Сбербанк <info@sberbank.ru>", "the sender's encoded name is decoded")
        #expect(content.text.contains("Уважаемый клиент"), "a KOI8-R quoted-printable body is decoded")
        #expect(content.attachments == ["Счёт.pdf", "photo.jpg"], "attachment names are decoded from filename* and from name, in order")
        #expect(content.entities.documentDate?.date == "2024-05-15", "an e-mail is dated the day it was sent")
    }

    @Test("eml with only an HTML body is stripped to text; .msg is metadata-only")
    func htmlAndMsg() async throws {
        let scratch = try Scratch()
        let html = try scratch.write("news.eml", """
        From: News <news@example.com>
        Subject: Weekly update
        Date: Mon, 2 Jun 2025 09:00:00 +0000
        Content-Type: text/html; charset=utf-8

        <html><head><style>p{color:red}</style></head><body><p>Hello &amp; welcome</p><p>Line&nbsp;two</p><p>Informa&ccedil;&atilde;o</p></body></html>
        """)
        let content = try await registry.extract(html, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.text.contains("Hello & welcome"), "an HTML body becomes text with its entities decoded")
        #expect(content.text.contains("Informação"), "accented letters written as references are read as letters")
        #expect(!content.text.contains("<p>"), "tags are stripped")
        #expect(!content.text.contains("color:red"), "style sheets are not text")

        let msg = try scratch.write("outlook.msg", data: Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]))
        let msgContent = try await registry.extract(msg, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(msgContent.kind == .email, "an Outlook .msg is still an e-mail")
        #expect(msgContent.warnings.map(\.code) == [.unsupportedFormat], "an Outlook .msg cannot be read, and the warning says so")
        #expect(msgContent.textOrigin == .metadataOnly, "an Outlook .msg is described by its metadata alone")
    }

    @Test("A UTF-8 body the cap cuts inside a letter stays UTF-8, up to the last whole letter, and the cut is noted")
    func bodyCutInsideALetter() async throws {
        let scratch = try Scratch()
        let body = String(repeating: "Счёт на оплату готов ", count: 20)
        let bytes = Array(body.utf8)
        // A cap past the first 100 bytes that falls on the second byte of a Cyrillic letter.
        let cap = try #require((100..<bytes.count).first { bytes[$0] & 0xC0 == 0x80 })
        let url = try scratch.write("cut.eml", data: EMLFixture.plain(body: body))
        let context = try TestConfig.context { extraction, _ in extraction.emailBodyCapBytes = cap }
        let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        let kept = String(decoding: bytes[..<(cap - 1)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        #expect(content.text.hasSuffix(kept), "the body is read as the UTF-8 it is, not as Latin-1, up to the letter the cap cut")
        #expect(content.warnings.map(\.detail) == ["body: first \(cap) bytes"], "the cut is noted, so the model knows it read part")
    }

    @Test("An e-mail longer than emailReadCapBytes is read up to it, and the cut is noted")
    func readCap() async throws {
        let scratch = try Scratch()
        let data = EMLFixture.plain(body: String(repeating: "Linha da mensagem.\n", count: 200) + "Fim da mensagem")
        let url = try scratch.write("long.eml", data: data)
        let cap = data.count / 2
        let context = try TestConfig.context { extraction, _ in extraction.emailReadCapBytes = cap }
        let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(content.metadata[MetadataKey.emailSubject] == EMLFixture.subject, "the headers before the cap are read")
        #expect(content.text.contains("Linha da mensagem."), "so is the body, up to the cap")
        #expect(!content.text.contains("Fim da mensagem"), "and nothing past it: the file is not read whole")
        #expect(content.warnings.map(\.detail) == ["read the first \(cap) of \(data.count) bytes"],
                "the cut is noted, so the model knows it read part")
    }

    @Test("zip: entry listing without unpacking; other archives metadata-only")
    func archives() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeZip("bundle.zip", files: ["fatura.pdf": "%PDF-1.4", "fotos/praia.jpg": "jpeg"])
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.kind == .archive, "a .zip is an archive")
        #expect(content.textOrigin == .metadataOnly, "a zip is listed, not unpacked")
        #expect(Set(content.attachments) == ["fatura.pdf", "fotos/praia.jpg"], "every entry is listed with its path")
        #expect(content.text.contains("fotos/praia.jpg"), "the listing is the text the model sees")
        #expect(content.metadata["archive:entries"] == "2", "the entry count is kept as metadata")

        let gzip = try scratch.write("logs.tar.gz", data: Data([0x1F, 0x8B, 0x08, 0x00]))
        let gzContent = try await registry.extract(gzip, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(gzContent.kind == .archive, "a .tar.gz is an archive")
        #expect(gzContent.warnings.map(\.code) == [.unsupportedFormat], "only zips are listed; other archives say so")
    }
}

// MARK: Fixtures

enum XLSXFixture {
    /// The package's relationships, naming the workbook at `target`.
    static func packageRelationships(target: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="\(target)"/>
        </Relationships>
        """
    }

    /// A workbook listing `sheets`, its `<sheet>` elements.
    static func workbook(_ sheets: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>\(sheets)</sheets>
        </workbook>
        """
    }

    /// A worksheet holding `rows`, its `<row>` elements.
    static func worksheet(_ rows: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        \(rows)
        </sheetData></worksheet>
        """
    }

    /// The parts of `files`, with the one at `path` replaced by `contents`.
    static func files(replacing path: String, with contents: String) -> [String: String] {
        var replaced = files
        replaced[path] = contents
        return replaced
    }

    static let files: [String: String] = [
        "[Content_Types].xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
        </Types>
        """,
        "_rels/.rels": packageRelationships(target: "xl/workbook.xml"),
        "xl/workbook.xml": workbook(#"<sheet name="Faturas" sheetId="1" r:id="rId1"/><sheet name="Resumo" sheetId="2" r:id="rId2"/>"#),
        "xl/_rels/workbook.xml.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        </Relationships>
        """,
        "xl/sharedStrings.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="5" uniqueCount="5">
        <si><t>Fornecedor</t></si><si><t>Valor</t></si><si><t>EDP Comercial</t></si><si><t>Galp</t></si><si><t>Total</t></si>
        </sst>
        """,
        "xl/worksheets/sheet1.xml": worksheet("""
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>45.9</v></c></row>
        <row r="3"><c r="A3" t="s"><v>3</v></c><c r="C3" t="inlineStr"><is><t>inline note</t></is></c></row>
        """),
        "xl/worksheets/sheet2.xml": worksheet(#"<row r="1"><c r="A1" t="s"><v>4</v></c><c r="B1"><v>45.9</v></c></row>"#),
    ]
}

enum PPTXFixture {
    /// A slide of `paragraphs`, each its runs.
    static func slide(_ paragraphs: [[String]]) -> String {
        let body = paragraphs.map { runs in
            "<a:p>" + runs.map { "<a:r><a:t>\($0)</a:t></a:r>" }.joined() + "</a:p>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody>\(body)</p:txBody></p:sp></p:spTree></p:cSld></p:sld>
        """
    }

    static let files: [String: String] = [
        "ppt/slides/slide1.xml": slide([["Quarterly", " review"], ["Revenue up"]]),
        "ppt/slides/slide10.xml": slide([["Tenth slide"]]),
        "ppt/slides/slide2.xml": slide([["Second slide"]]),
        "ppt/notesSlides/notesSlide1.xml": slide([["Speaker note one"]]),
    ]
}

enum EMLFixture {
    static let subject = "Fatura de julho"

    /// A message whose only part is `body`, as UTF-8 plain text.
    static func plain(body: String) -> Data {
        Data("""
        From: Loja <loja@example.com>
        Subject: \(subject)
        Date: Mon, 2 Jun 2025 09:00:00 +0000
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 8bit

        \(body)
        """.utf8)
    }

    static func message() throws -> Data {
        let koi8 = try #require(TextEncodingDetector.encoding(named: "koi8R"))
        let body = try #require("Уважаемый клиент! Ваш счёт от 15.05.2024 готов.".data(using: koi8))
        let quotedPrintable = body.map { byte in
            byte >= 0x80 || byte == UInt8(ascii: "=") ? "=" + String(byte, radix: 16, uppercase: true) : String(UnicodeScalar(byte))
        }.joined()
        let from = Data("ПАО Сбербанк".utf8).base64EncodedString()
        let subjectTail = Data(" от 15 мая".utf8).base64EncodedString()
        let message = """
        From: =?UTF-8?B?\(from)?= <info@sberbank.ru>
        To: Dmitry <d@example.com>
        Subject: =?UTF-8?Q?Fatura_n=C2=BA_123_=E2=80=94_EDP?=
         =?UTF-8?B?\(subjectTail)?=
        Date: Wed, 15 May 2024 10:52:37 +0200
        Message-ID: <abc@sberbank.ru>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="XYZ"

        This is a multi-part message in MIME format.
        --XYZ
        Content-Type: multipart/alternative; boundary="ALT"

        --ALT
        Content-Type: text/plain; charset=koi8-r
        Content-Transfer-Encoding: quoted-printable

        \(quotedPrintable)
        --ALT
        Content-Type: text/html; charset=utf-8

        <p>HTML version</p>
        --ALT--
        --XYZ
        Content-Type: application/pdf
        Content-Disposition: attachment; filename*=UTF-8''%D0%A1%D1%87%D1%91%D1%82.pdf
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --XYZ
        Content-Type: image/jpeg; name="photo.jpg"
        Content-Transfer-Encoding: base64

        /9j/4AAQ
        --XYZ--
        """
        return Data(message.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }
}
