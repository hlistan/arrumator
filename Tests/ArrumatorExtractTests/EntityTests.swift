import ArrumatorCore
@testable import ArrumatorExtract
import ArrumatorTesting
import Foundation
import Testing

@Suite("Entities and document dates")
struct EntityTests {
    /// Fixed "today" so plausibility windows do not drift, in a calendar of its own.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 22)) ?? TestTime.start }

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
        #expect(resolution.chosen?.date == CalendarDay(date: created, calendar: .current).iso, "the file's creation day, in local time")
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
