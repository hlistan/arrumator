import ArrumatorCore
@testable import ArrumatorExtract
import Foundation
import Testing

@Suite("Entities and document dates")
struct EntityTests {
    /// Fixed "today" so plausibility windows do not drift.
    private let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 22)) ?? Date()
    }()

    private func resolve(_ text: String, metadata: [MetadataDate] = [], created: Date? = nil,
                         modified: Date? = nil) throws -> DateResolution {
        let entities = try TestConfig.pipeline().entities
        let scan = EntityExtractor(config: entities).scan(text, now: now)
        let evidence = DateEvidence(firstPageLength: nil, metadataDates: metadata, fileCreated: created,
                                    fileModified: modified, now: now)
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
        #expect(resolution.chosen?.date == "2024-03-12")
        #expect(resolution.chosen?.source == .label)
        let due = resolution.scored.first { $0.date == "2024-04-11" }
        #expect(due?.label?.lowercased() == "due date")
        #expect((due?.score ?? 99) < (resolution.chosen?.score ?? 0))
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
        #expect(resolution.chosen?.date == "2024-05-15")
        #expect(resolution.chosen?.source == .label)
        #expect(resolution.scored.first { $0.date == "2024-05-30" }?.label == "Срок оплаты")
        #expect(resolution.scored.first { $0.date == "1980-01-01" }?.eligible == false)
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
        #expect(resolution.chosen?.date == "2026-05-20")
        #expect(resolution.chosen?.source == .label)
        #expect(resolution.scored.first { $0.date == "2026-06-30" }?.label == "vencimento")
    }

    @Test("A lone birth date is never chosen; falls back to file dates")
    func birthOnly() throws {
        let created = now.addingTimeInterval(-86_400 * 3)
        let resolution = try resolve("Nome: Maria Silva\nData de nascimento: 03/04/2015", created: created, modified: now)
        #expect(resolution.scored.first?.eligible == true)
        #expect(resolution.scored.first?.label == "Data de nascimento")
        #expect(resolution.chosen?.source == .fileCreated)
        #expect(resolution.chosen?.date == CalendarDay(date: created, calendar: .current).iso)
    }

    @Test("EXIF date is used without text dates and boosts an equal text date")
    func metadataDates() throws {
        let exif = MetadataDate(day: try #require(CalendarDay(year: 2023, month: 7, day: 14)), source: .exif,
                                label: "EXIF DateTimeOriginal")
        #expect(try resolve("Whiteboard notes", metadata: [exif]).chosen?.source == .exif)
        #expect(try resolve("Whiteboard notes", metadata: [exif]).chosen?.date == "2023-07-14")
        let resolution = try resolve("Receipt\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n14.07.2023 total", metadata: [exif])
        #expect(resolution.scored.first?.reasons.contains("matchesMetadata") == true)
        #expect(resolution.chosen?.date == "2023-07-14")
    }

    @Test("Crowded statement lines are penalised")
    func crowded() throws {
        let text = "Statement\n01.03.2024 02.03.2024 03.03.2024 movements"
        let resolution = try resolve(text)
        #expect(resolution.scored.allSatisfy { $0.reasons.contains { $0.hasPrefix("crowdedLine") } })
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
            #expect(days.contains(expected), "missing \(expected)")
        }
        // 31.02.2025 must not come back as a rolled-over 3 March.
        #expect(!days.contains("2025-03-03"))
        #expect(!days.contains { $0.hasPrefix("2025-02-3") })
        #expect(!days.contains("2024-05-01"))
    }

    @Test("Money in EUR, RUB, BRL and USD notations")
    func money() {
        let amounts = EntityExtractor.amounts(in: """
        Total a pagar: 1.234,56 €; Итого: 12 500,00 руб.; R$ 99,90; $1,234.56; EUR 10; 300 ₽
        """)
        let pairs = Set(amounts.map { "\($0.value) \($0.currency)" })
        #expect(pairs == ["1234.56 EUR", "12500.00 RUB", "99.90 BRL", "1234.56 USD", "10 EUR", "300 RUB"])
    }

    @Test("E-mails, URLs, phones and stable keys; phones never duplicate identifiers")
    func scan() throws {
        let entities = try TestConfig.pipeline().entities
        let scan = EntityExtractor(config: entities).scan("""
        Contact: Faturacao@EDP.pt, https://www.edp.pt/faturas
        Tel. +351 210 002 800
        IBAN PT50 0002 0123 1234 5678 9015 4
        """, now: now)
        #expect(scan.emails == ["faturacao@edp.pt"])
        #expect(scan.urls.contains { $0.contains("edp.pt/faturas") })
        #expect(scan.phones.count == 1)
        #expect(scan.stableKeys.map(\.kind) == [.iban])
    }
}
