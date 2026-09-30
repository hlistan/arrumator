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
        #expect(capped.structure?.sheetNames == ["Faturas", "Resumo"], "every sheet name is listed, even of sheets left out")
        #expect(capped.warnings.map(\.detail) == ["sheet Faturas: first 2 rows", "first 1 of 2 sheets"],
                "what was cut is noted, so the model knows it saw part of the workbook")
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

        <html><head><style>p{color:red}</style></head><body><p>Hello &amp; welcome</p><p>Line&nbsp;two</p></body></html>
        """)
        let content = try await registry.extract(html, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.text.contains("Hello & welcome"), "an HTML body becomes text with its entities decoded")
        #expect(!content.text.contains("<p>"), "tags are stripped")
        #expect(!content.text.contains("color:red"), "style sheets are not text")

        let msg = try scratch.write("outlook.msg", data: Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]))
        let msgContent = try await registry.extract(msg, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(msgContent.kind == .email, "an Outlook .msg is still an e-mail")
        #expect(msgContent.warnings.map(\.code) == [.unsupportedFormat], "an Outlook .msg cannot be read, and the warning says so")
        #expect(msgContent.textOrigin == .metadataOnly, "an Outlook .msg is described by its metadata alone")
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
        "_rels/.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """,
        "xl/workbook.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Faturas" sheetId="1" r:id="rId1"/><sheet name="Resumo" sheetId="2" r:id="rId2"/></sheets>
        </workbook>
        """,
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
        "xl/worksheets/sheet1.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>45.9</v></c></row>
        <row r="3"><c r="A3" t="s"><v>3</v></c><c r="C3" t="inlineStr"><is><t>inline note</t></is></c></row>
        </sheetData></worksheet>
        """,
        "xl/worksheets/sheet2.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>4</v></c><c r="B1"><v>45.9</v></c></row>
        </sheetData></worksheet>
        """,
    ]
}

enum PPTXFixture {
    private static func slide(_ paragraphs: [[String]]) -> String {
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
