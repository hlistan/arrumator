/// Files the app must not file normally: a self-made spreadsheet, a duplicate, a blank scan, an encrypted and
/// a truncated PDF.
enum NegativeFixtures {
    /// User password of the encrypted fixture (recorded in expected.json; the app is not supposed to know it).
    static let password = "arrumator-fixture"

    static func all(cast: Cast, seed: UInt64) -> [Fixture] {
        [budget(seed: seed), duplicate(), blankScan(), encrypted(cast: cast, seed: seed), truncated(cast: cast, seed: seed)]
    }

    static func budget(seed: UInt64) -> Fixture {
        let file = "negative/90-budget-2026.xlsx"
        var fake = Fake(seed: seed, salt: file)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let categories: [(String, ClosedRange<Double>)] = [
            ("Rent", 950...950), ("Electricity", 45...75), ("Water", 14...26), ("Internet & TV", 56.58...56.58),
            ("Groceries", 280...420), ("Transport", 40...90), ("Health insurance", 39...39), ("Eating out", 60...180),
        ]
        let salary = Money(2_184, 57)
        let expenses = categories.map { category in months.map { _ in fake.money(category.1) } }
        let firstExpenseRow = 5
        let lastExpenseRow = firstExpenseRow + categories.count - 1
        let expenseRow = lastExpenseRow + 2
        // Columns B…M are the months, N the yearly total.
        let columns = (1...13).map { String(UnicodeScalar(UInt8(65 + $0))) }
        func monthly(_ month: Int) -> Money { expenses.reduce(Money.zero) { $0 + $1[month] } }
        let monthlyExpenses = months.indices.map(monthly) + [expenses.flatMap { $0 }.reduce(Money.zero, +)]
        var rows: [[Cell]] = [
            [.text("Household budget 2026", bold: true)],
            [],
            [.text("Category", bold: true)] + (months + ["Total"]).map { .text($0, bold: true) },
            [.text("Salary (net)")] + months.map { _ in .money(salary) } + [.formula("SUM(B4:M4)", cached: Money(cents: salary.cents * 12))],
        ]
        for (index, category) in categories.enumerated() {
            let row = firstExpenseRow + index
            rows.append([.text(category.0)] + expenses[index].map { .money($0) }
                        + [.formula("SUM(B\(row):M\(row))", cached: expenses[index].reduce(Money.zero, +))])
        }
        rows.append([])
        rows.append([.text("Expenses", bold: true)] + zip(columns, monthlyExpenses).map { column, total in
            .formula("SUM(\(column)\(firstExpenseRow):\(column)\(lastExpenseRow))", cached: total, bold: true)
        })
        let incomes = Array(repeating: salary, count: 12) + [Money(cents: salary.cents * 12)]
        rows.append([.text("Balance", bold: true)] + zip(columns, zip(incomes, monthlyExpenses)).map { column, pair in
            .formula("\(column)4-\(column)\(expenseRow)", cached: pair.0 - pair.1, bold: true)
        })
        rows.append([])
        rows.append([.text("Notes: keep a 10% emergency fund; review the electricity tariff in October.")])
        let workbook = Workbook(title: "Household budget 2026", creator: "Alex Sample", created: Day(2026, 1, 4),
                                sheets: [Sheet(name: "Budget 2026", columnWidths: [22] + Array(repeating: 10, count: 13), rows: rows)])
        return .heldBack(file, .en, .xlsx, category: "02", type: .other, titleContains: ["Budget"], payload: .xlsx(workbook))
    }

    static func duplicate() -> Fixture {
        .heldBack("negative/91-edp-fatura-2026-07-copy.pdf", .pt, .pdfText, category: "03", type: nil,
                  duplicateOf: "pt/01-edp-fatura-2026-07.pdf", payload: .copy(of: "pt/01-edp-fatura-2026-07.pdf"))
    }

    static func blankScan() -> Fixture {
        let info = DocumentInfo(title: "", author: "", subject: "", created: Day(2026, 9, 10))
        return .heldBack("negative/92-blank-scan.pdf", .und, .pdfScan, category: "02", type: nil, warnings: [.emptyText],
                         payload: .pdfScan(.blank(info)))
    }

    static func encrypted(cast: Cast, seed: UInt64) -> Fixture {
        let file = "negative/93-encrypted.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 7, 22)
        let price = Money(549, 99)
        let document = Document(
            info: DocumentInfo(title: "Fatura Worten", author: "Worten", subject: "Fatura", created: issued),
            accent: RGB(hex: 0xE30613), pageNumbers: .pt,
            blocks: [
                .wordmark("worten", tagline: "Worten – Equipamentos para o Lar, S.A."),
                .title("Fatura-recibo FR \(fake.reference(8))"),
                .fields([Field("Data de emissão", issued.ptNumeric), Field("Cliente", cast.maria.name), Field("NIF", cast.maria.nif)]),
                .table(Table([Column("Artigo", 0.7), Column("Valor", 0.3, .right)],
                             rows: [["Máquina de lavar roupa 9 kg, classe A", price.eurPT]],
                             totals: [["Total (IVA incluído)", price.eurPT]])),
                .paragraph("Garantia de 3 anos a contar da data da fatura. Guarde este documento."),
            ])
        return .heldBack(file, .pt, .pdfText, category: "02", type: nil, warnings: [.encrypted], password: password,
                         payload: .encryptedPDF(document, password: password))
    }

    static func truncated(cast: Cast, seed: UInt64) -> Fixture {
        let file = "negative/94-corrupt.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 6, 2)
        let document = Document(
            info: DocumentInfo(title: "Invoice", author: "Namecheap", subject: "Domain renewal", created: issued),
            accent: RGB(hex: 0xDE3723), pageNumbers: .en,
            blocks: [
                .wordmark("namecheap", tagline: "Namecheap, Inc."),
                .title("Invoice \(fake.reference(8))"),
                .fields([Field("Date", issued.enLong), Field("Customer", cast.alexName)]),
                .table(Table([Column("Item", 0.7), Column("Amount", 0.3, .right)],
                             rows: [["Domain renewal example-sample.dev (1 year)", Money(14, 98).eurEN]],
                             totals: [["Total", Money(14, 98).eurEN]])),
            ])
        return .heldBack(file, .en, .pdfText, category: "02", type: nil, warnings: [.corrupted],
                         payload: .truncatedPDF(document))
    }
}
