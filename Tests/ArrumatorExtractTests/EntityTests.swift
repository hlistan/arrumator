import ArrumatorCore
@testable import ArrumatorExtract
import ArrumatorTesting
import AVFoundation
import Foundation
import PDFKit
import Testing

@Suite("Entities and document dates")
struct EntityTests {
    /// Fixed "today" so plausibility windows do not drift, in a calendar of its own.
    private let calendar = GregorianCalendar(timeZone: .gmt)
    private var now: Date {
        TestConfig.calendar.date(from: DateComponents(year: 2026, month: 9, day: 22)) ?? TestTime.start
    }

    private func resolve(_ text: String, metadata: [MetadataDate] = [], created: Date? = nil,
                         modified: Date? = nil) throws -> DateResolution {
        let entities = try TestConfig.pipeline().entities
        let scan = EntityExtractor(config: entities).scan(text, now: now, calendar: calendar)
        let evidence = DateEvidence(firstPageLength: nil, metadataDates: metadata, fileCreated: created,
                                    fileModified: modified, now: now, calendar: calendar)
        return DocumentDateResolver(config: entities).resolve(scan.dateCandidates, in: text, evidence: evidence)
    }

    @Test("English: invoice date wins over due date and date of birth")
    func english() throws {
        let text = """
        ACME Ltd
        Invoice date: 12/03/2024
        Due date: 11/04/2024
        Customer DOB: 01/02/1985
        """
        let resolution = try resolve(text)
        #expect(resolution.chosen?.date == "2024-03-12", "the invoice date dates the document, day first")
        #expect(resolution.chosen?.source == .label, "it wins by its label")
        let due = resolution.scored.first { $0.date == "2024-04-11" }
        #expect(due?.label?.lowercased() == "due date", "the due date is recognised by its label")
        #expect((due?.score ?? 99) < (resolution.chosen?.score ?? 0), "and scores below the invoice date")
    }

    @Test("Russian: «от 15 мая 2024 г.» wins over срок оплаты and дата рождения")
    func russian() throws {
        let text = """
        ООО «Ромашка»
        Счёт на оплату № 15 от 15 мая 2024 г.
        Срок оплаты: 30.05.2024
        Дата рождения: 01.01.1980
        """
        let resolution = try resolve(text)
        #expect(resolution.chosen?.date == "2024-05-15", "«от» with a month in words dates a Russian invoice")
        #expect(resolution.chosen?.source == .label, "it wins by its label")
        #expect(resolution.scored.first { $0.date == "2024-05-30" }?.label == "Срок оплаты", "the payment deadline is recognised by its label")
        #expect(resolution.scored.first { $0.date == "1980-01-01" }?.eligible == false, "a date of birth decades back is outside the plausible years")
    }

    @Test("Portuguese: data de emissão wins even after the due date")
    func portuguese() throws {
        let text = """
        Fatura FT 2026/123
        Data de vencimento: 30/06/2026
        Data de emissão: 20 de maio de 2026
        Data de nascimento: 03/04/1979
        """
        let resolution = try resolve(text)
        #expect(resolution.chosen?.date == "2026-05-20", "the issue date wins even though the due date comes first")
        #expect(resolution.chosen?.source == .label, "it wins by its label")
        #expect(resolution.scored.first { $0.date == "2026-06-30" }?.label == "vencimento", "the due date is recognised by its label")
    }

    @Test("A lone birth date is never chosen; falls back to file dates")
    func birthOnly() throws {
        let created = now.addingTimeInterval(-86_400 * 3)
        let resolution = try resolve("Nome: Maria Silva\nData de nascimento: 03/04/2015", created: created, modified: now)
        #expect(resolution.scored.first?.eligible == true, "a child's birth date is in the plausible years")
        #expect(resolution.scored.first?.label == "Data de nascimento", "it is recognised as a birth date by its label")
        #expect(resolution.chosen?.source == .fileCreated, "so the birth label keeps it from dating the document, and the file date does")
        #expect(resolution.chosen?.date == calendar.day(of: created).iso, "the file's creation day, in the Mac's time zone")
    }

    @Test("EXIF date is used without text dates and boosts an equal text date")
    func metadataDates() throws {
        let exif = MetadataDate(day: try #require(CalendarDay(year: 2023, month: 7, day: 14)), source: .exif,
                                label: "EXIF DateTimeOriginal")
        #expect(try resolve("Whiteboard notes", metadata: [exif]).chosen?.source == .exif, "with no date in the text, the photo is dated when it was taken")
        #expect(try resolve("Whiteboard notes", metadata: [exif]).chosen?.date == "2023-07-14", "the EXIF day is the date")
        let resolution = try resolve("Receipt\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n14.07.2023 total", metadata: [exif])
        let textDate = try #require(resolution.scored.first)
        #expect(textDate.reasons.contains("matchesMetadata"), "a text date equal to the EXIF date is boosted")
        #expect(resolution.chosen?.date == "2023-07-14", "the boost lets an unlabelled date far down the page win")
    }

    @Test("Crowded statement lines are penalised")
    func crowded() throws {
        let text = "Statement\n01.03.2024 02.03.2024 03.03.2024 movements"
        let resolution = try resolve(text)
        #expect(resolution.scored.map { $0.reasons.contains("crowdedLine 3") } == [true, true, true],
                "each date on a line of statement movements is penalised, so none passes for the issue date")
    }

    @Test("Months named in any language and form, CJK, ISO and numeric dates")
    func dateScanning() throws {
        let text = """
        «1» января 2025 г.; 4 марта 2025; 12 декабря 2024
        5 de março de 2025, 7 fev 2025, 8 marco 2025
        May 20, 2026 and 21st of May 2026; Sept. 3 2025
        3. März 2024; 1er avril 2024; 15 maja 2024; 9 Μαρτίου 2024; 2024年6月7日; 2024년 8월 9일
        V Praze dne 24. 9. 2023; 2023. 10. 11.
        2026-01-31; 31/12/2025; 05/13/2025
        31.02.2025 is not a date; neither is May 2024 alone
        """
        let days = Set(DateScanner(twoDigitYearPivot: 2027).candidates(in: text).map(\.day.iso))
        for expected in ["2025-01-01", "2025-03-04", "2024-12-12", "2025-03-05", "2025-02-07", "2026-05-20",
                         "2026-05-21", "2026-01-31", "2025-12-31", "2025-05-13", "2025-03-08", "2025-09-03", "2024-03-03",
                         "2024-04-01", "2024-05-15", "2024-03-09", "2024-06-07", "2024-08-09", "2023-09-24", "2023-10-11"] {
            #expect(days.contains(expected), "\(expected) is found, however its month is written")
        }
        // 31.02.2025 must not come back as a rolled-over 3 March.
        #expect(!days.contains("2025-03-03"), "an impossible day is dropped, not rolled over into March")
        #expect(!days.contains { $0.hasPrefix("2025-02-3") }, "no 30th or 31st of February is reported")
        #expect(!days.contains("2024-05-01"), "a month and year alone is not a day")
    }

    @Test("A date in the digits of any script is read; both ends of a range written without spaces are read day first")
    func digitsAndRanges() {
        let scanner = DateScanner(twoDigitYearPivot: 2027)
        let scripts = [("\u{062A}\u{0627}\u{0631}\u{064A}\u{062E}: \u{0662}\u{0660}/\u{0660}\u{0665}/\u{0662}\u{0660}\u{0662}\u{0666}", "Arabic-Indic"),
                       ("\u{0924}\u{093E}\u{0930}\u{0940}\u{0916}: \u{0968}\u{0966}.\u{0966}\u{096B}.\u{0968}\u{0966}\u{0968}\u{096C}", "Devanagari"),
                       ("\u{FF12}\u{FF10}\u{FF12}\u{FF16}\u{5E74}\u{FF15}\u{6708}\u{FF12}\u{FF10}\u{65E5}", "full-width")]
        for (text, digits) in scripts {
            #expect(scanner.candidates(in: text).map(\.day.iso) == ["2026-05-20"], "a date in \(digits) digits is the day it writes: \(text)")
        }
        let ranges = [("01/03/2024-31/03/2024", ["01/03/2024", "31/03/2024"], "2024-03-01"),
                      ("01.03.2024-31.03.2024", ["01.03.2024", "31.03.2024"], "2024-03-01"),
                      ("02/03/24-31/03/24", ["02/03/24", "31/03/24"], "2024-03-02")]
        for (range, ends, start) in ranges {
            let found = scanner.candidates(in: "Período de faturação: \(range)")
            #expect(found.map(\.matched) == ends, "each end of \(range) is a date of its own, read by the day-first rule")
            #expect(found.map(\.day.iso) == [start, "2024-03-31"], "so the first number is the day, wherever the Mac is")
        }
        #expect(scanner.candidates(in: "Ref. 12/03/2024-5").isEmpty, "a number after a date's dash is no second date, nor makes the first one")
    }

    @Test("A date is read, weighed and written in the Gregorian calendar, whatever calendar the Mac is set to",
          arguments: [Calendar.Identifier.buddhist, .japanese])
    func gregorianOnEveryMac(_ identifier: Calendar.Identifier) async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let registry = try TestConfig.registry(calendar: TestConfig.calendar(identifier, in: .gmt))
        let context = try TestConfig.context()
        let invoice = try scratch.write("fatura.txt", "Fatura FT 2026/0042\nData de emissão: 20/05/2026\nVence a 10/06/26\n")
        let read = try await registry.extract(invoice, sha256: "x", context: context, trace: .disabled)
        #expect(read.entities.documentDate?.date == "2026-05-20",
                "\(identifier): a date of this year is plausible, so its label dates the document (\(String(describing: read.entities.documentDate)))")
        #expect(read.entities.documentDate?.source == .label, "\(identifier): it is the text's date, not a file date")
        #expect(read.entities.dates.contains { $0.date == "2026-06-10" },
                "\(identifier): a two-digit year is read in this century (\(read.entities.dates.map(\.date)))")

        let note = try scratch.write("nota.txt", "Uma nota sem data nenhuma, sobre as obras do prédio.")
        let undated = try await registry.extract(note, sha256: "x", context: context, trace: .disabled)
        let noted = try #require(undated.source.createdAt)
        #expect(undated.entities.documentDate?.date == calendar.day(of: noted).iso,
                "\(identifier): a file's own date is written as the Gregorian day it is")

        // Core Graphics dates a PDF when it writes it: read on that day, the PDF's date is of this year.
        let letter = try scratch.writeTextPDF("carta.pdf", pages: [["Carta sem data sobre o contrato e as obras do prédio."]])
        let created = try #require(PDFDocument(url: letter)?.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date)
        let then = try TestConfig.registry(time: TestTime(.blocks, at: created), calendar: TestConfig.calendar(identifier, in: .gmt))
        let pdf = try await then.extract(letter, sha256: "x", context: context, trace: .disabled)
        #expect(pdf.entities.documentDate?.source == .pdfMeta, "\(identifier): the PDF's creation date dates it (\(pdf.warningSummary))")
        #expect(pdf.entities.documentDate?.date == calendar.day(of: created).iso,
                "\(identifier): the creation date is the Gregorian day the PDF says")
    }

    @Test("A PDF's creation date is the day it writes, with its offset or without, wherever the Mac is",
          arguments: ["D:20240520013000+02'00'", "D:20240520013000", "D:20240520233000-05'00'", "D:20240520"])
    func pdfDayAsWritten(written: String) async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.writePDF("criado.pdf", creationDate: written)
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        for zone in [newYork, tokyo] {
            let registry = try TestConfig.registry(recognizer: RecordingRecognizer(), calendar: TestConfig.calendar(.gregorian, in: zone))
            let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
            #expect(content.entities.documentDate?.source == .pdfMeta, "\(written): the PDF's own date dates it (\(content.warningSummary))")
            #expect(content.entities.documentDate?.date == "2024-05-20",
                    "\(written), on a Mac in \(zone.identifier): the day the PDF writes, not the day the moment was there")
        }
    }

    @Test("A recording's capture date is the day it writes, in its own offset, wherever the Mac is")
    func mediaDayAsWritten() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let silence = scratch.url("silencio.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        try AVAudioFile(forWriting: silence, settings: format.settings).write(from: buffer)
        let captured = AVMutableMetadataItem()
        captured.identifier = .quickTimeMetadataCreationDate
        captured.value = "2024-05-20T01:30:00+0200" as NSString
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: silence), presetName: AVAssetExportPresetPassthrough))
        session.metadata = [captured]
        let url = scratch.url("gravacao.mov")
        try await session.export(to: url, as: .mov)
        let registry = try TestConfig.registry(calendar: TestConfig.calendar(.gregorian, in: try #require(TimeZone(identifier: "America/New_York"))))
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.metadata["media:creationDate"] == "2024-05-19T23:30:00Z", "the moment it was captured is kept, in UTC")
        #expect(content.entities.documentDate?.date == "2024-05-20",
                "on a Mac in New York the recording is dated the day its camera's clock showed, not the 19th (\(content.warningSummary))")
    }

    @Test("The identifier rules built for one configuration serve every file read with it, and a new one gets its own")
    func identifierRulesFollowTheConfiguration() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let url = try scratch.write("conta.txt", "Kundennummer: 4711 0815\nCustomer number: 12345678")
        let registry = try TestConfig.registry()
        let bundled = try TestConfig.context()
        let german = try TestConfig.context { _, entities in entities.accountLabels = ["Kundennummer"] }
        for (context, keys) in [(bundled, ["accountNumber:12345678"]), (bundled, ["accountNumber:12345678"]),
                                (german, ["accountNumber:47110815"]), (bundled, ["accountNumber:12345678"])] {
            let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
            #expect(content.entities.stableKeys.map(\.token) == keys, "each file is read with the labels of its own configuration")
        }
    }

    @Test("Identifiers are found with their checksums; nothing else a document says is taken for one")
    func scan() throws {
        let entities = try TestConfig.pipeline().entities
        let scan = EntityExtractor(config: entities).scan("""
        Contact: Faturacao@EDP.pt, https://www.edp.pt/faturas
        Tel. +351 210 002 800
        IBAN PT50 0002 0123 1234 5678 9015 4
        """, now: now, calendar: calendar)
        #expect(scan.stableKeys.map(\.kind) == [.iban], "the IBAN, checked by its mod-97 remainder, and not the phone number")
        #expect(scan.stableKeys.first?.value == "PT50000201231234567890154", "written without its spaces, as it is matched")
    }
}
