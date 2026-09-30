import CoreGraphics

/// English-language documents of Alex Sample (a UK national living in Lisbon).
enum EnglishFixtures {
    static func all(cast: Cast, seed: UInt64) -> [Fixture] {
        [
            employmentAgreement(cast: cast, seed: seed),
            payslip(cast: cast, seed: seed),
            hostingInvoice(cast: cast, seed: seed),
            softwareLicence(cast: cast, seed: seed),
            transferScreenshot(cast: cast, seed: seed),
            flightBooking(cast: cast, seed: seed),
            passportScan(cast: cast, seed: seed),
            appointmentEmail(cast: cast, seed: seed),
        ]
    }

    private static let acmeAccent = RGB(hex: 0x3A3F99)
    private static let acmeFooter = "Acme Ltd · 1 Example Street, London EC1A 1AA · Registered in England and Wales, company number 01234567"
    private static let lisbonAddress = ["Rua Exemplo 12, 3.º Esq.", "1000-001 Lisboa", "Portugal"]

    // MARK: 40 employment agreement (DOCX), 41 payslip

    static func employmentAgreement(cast: Cast, seed: UInt64) -> Fixture {
        let file = "en/40-acme-employment-agreement.docx"
        let signed = Day(2024, 1, 15)
        let salary = Money(68_000)
        let document = Document(
            info: DocumentInfo(title: "Employment Agreement – Alex Sample", author: "Acme Ltd", subject: "Contract of employment", created: signed),
            family: .serif, accent: .black,
            blocks: [
                .title("EMPLOYMENT AGREEMENT", alignment: .center),
                .paragraph("This Employment Agreement (the \"Agreement\") is dated \(signed.enLong)."),
                .strong("PARTIES"),
                .paragraph("(1) ACME LTD, a company incorporated in England and Wales with company number 01234567, whose registered office is at 1 Example Street, London EC1A 1AA (the \"Company\"); and"),
                .paragraph("(2) \(cast.alexName.uppercased()) of \(lisbonAddress.joined(separator: ", ")) (the \"Employee\")."),
                .heading("1. Commencement and job title"),
                .paragraph("1.1 The Employee's employment under this Agreement will begin on 1 February 2024. No period of previous employment counts towards the Employee's period of continuous employment."),
                .paragraph("1.2 The Employee is employed as Senior Software Engineer and reports to the Head of Engineering."),
                .heading("2. Place of work"),
                .paragraph("2.1 The Employee will work remotely from Portugal and will attend the Company's London office for up to four weeks per year, with reasonable travel expenses reimbursed."),
                .heading("3. Hours of work"),
                .paragraph("3.1 Normal working hours are 37.5 hours per week, Monday to Friday. The Employee may be required to work additional hours when the needs of the business require, without further remuneration."),
                .heading("4. Salary"),
                .paragraph("4.1 The Employee's salary is \(salary.gbp) per year, which accrues from day to day and is payable monthly in arrears on or about the last working day of each month by bank transfer."),
                .paragraph("4.2 The salary will be reviewed annually. There is no obligation to increase it."),
                .heading("5. Holidays"),
                .paragraph("5.1 The holiday year runs from 1 January to 31 December. The Employee is entitled to 25 working days' paid holiday in each holiday year, in addition to the public holidays of the place of work."),
                .heading("6. Pension"),
                .paragraph("6.1 The Company will enrol the Employee in its workplace pension scheme. The Employee contributes 5% and the Company 4% of qualifying earnings."),
                .heading("7. Confidentiality and intellectual property"),
                .paragraph("7.1 The Employee shall not, during or after the employment, disclose any confidential information of the Company. All intellectual property created by the Employee in the course of the employment belongs to the Company."),
                .heading("8. Termination"),
                .paragraph("8.1 After the probationary period of three months, either party may terminate the employment by giving three months' written notice."),
                .heading("9. Governing law"),
                .paragraph("9.1 This Agreement is governed by the law of England and Wales, without prejudice to mandatory provisions of the law of the place of work."),
                .gap,
                .columns(left: ["Signed for and on behalf of Acme Ltd", "", "______________________________", "Jane Example, Director"],
                         right: ["Signed by the Employee", "", "______________________________", cast.alexName]),
            ])
        return .filed(file, .en, .docx, type: .contract,
                      correspondent: "Acme Ltd", date: signed,
                      titleContains: ["Employment", "Agreement"], payload: .docx(document))
    }

    static func payslip(cast: Cast, seed: UInt64) -> Fixture {
        let file = "en/41-acme-payslip-2026-08.pdf"
        var fake = Fake(seed: seed, salt: file)
        let paid = Day(2026, 8, 31)
        let basic = Money(5_900)
        let allowance = Money(50)
        let gross = basic + allowance
        let incomeTax = Money(1_188, 47)
        let insurance = Money(286, 50)
        let pension = gross.percent(5)
        let deductions = incomeTax + insurance + pension
        let document = Document(
            info: DocumentInfo(title: "Payslip August 2026", author: "Acme Ltd", subject: "Payslip", created: paid),
            accent: acmeAccent, footer: acmeFooter, pageNumbers: .en,
            blocks: [
                .wordmark("ACME", tagline: "Acme Ltd · Payroll"),
                .title("Payslip"),
                .subtitle("Pay period: August 2026"),
                .columns(left: [cast.alexName] + lisbonAddress, right: ["Employee no. 00427", "NI number \(cast.alexNINumber)", "Tax code 1257L", "Tax period: Month 5 (2026/27)"]),
                .fields([
                    Field("Pay date", paid.enLong),
                    Field("Period", "1 August 2026 – 31 August 2026"),
                    Field("Payment method", "Bank transfer (BACS)"),
                    Field("Department", "Engineering"),
                ]),
                .heading("Payments"),
                .table(Table([Column("Description", 0.52), Column("Units", 0.12, .right), Column("Rate", 0.16, .right), Column("Amount", 0.2, .right)],
                             rows: [["Basic salary", "1", basic.gbp, basic.gbp], ["Wellbeing allowance", "1", allowance.gbp, allowance.gbp]],
                             totals: [["Gross pay", "", "", gross.gbp]])),
                .heading("Deductions"),
                .table(Table([Column("Description", 0.8), Column("Amount", 0.2, .right)],
                             rows: [["Income tax (PAYE)", incomeTax.gbp], ["National Insurance (category A)", insurance.gbp],
                                    ["Pension – employee contribution 5%", pension.gbp]],
                             totals: [["Total deductions", deductions.gbp]])),
                .banner("Net pay: \((gross - deductions).gbp)"),
                .heading("Year to date"),
                .table(Table([Column("", 0.5), Column("Gross", 0.125, .right), Column("Tax", 0.125, .right), Column("NI", 0.125, .right),
                              Column("Pension", 0.125, .right)],
                             rows: [["Tax year 2026/27 to date", Money(cents: gross.cents * 5).gbp, Money(cents: incomeTax.cents * 5).gbp,
                                     Money(cents: insurance.cents * 5).gbp, Money(cents: pension.cents * 5).gbp]])),
                .note("Payment reference \(fake.letters(3))\(fake.reference(7)). Please keep this payslip for your records; it is not reissued."),
            ])
        return .filed(file, .en, .pdfText, type: .payslip,
                      correspondent: "Acme Ltd", date: paid,
                      titleContains: ["August", "2026"], payload: .pdfText(document))
    }

    // MARK: 42 Hetzner, 43 JetBrains

    static func hostingInvoice(cast: Cast, seed: UInt64) -> Fixture {
        let file = "en/42-hetzner-invoice-2026-09.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 9, 1)
        let items: [(String, Money)] = [
            ("Cloud Server CPX31 (#\(fake.reference(8)))", Money(15, 59)),
            ("Primary IPv4 address", Money(0, 50)),
            ("Backups for CPX31 (20%)", Money(3, 12)),
            ("Volume 50 GB (#\(fake.reference(8)))", Money(2, 20)),
            ("Storage Box BX11", Money(3, 81)),
        ]
        let net = items.reduce(Money.zero) { $0 + $1.1 }
        let vat = net.percent(23)
        let document = Document(
            info: DocumentInfo(title: "Invoice R\(fake.reference(10))", author: "Hetzner Online GmbH", subject: "Invoice", created: issued),
            accent: RGB(hex: 0xD50C2D),
            footer: "Hetzner Online GmbH · Beispielstraße 1 · 91710 Gunzenhausen · Germany · www.hetzner.com",
            pageNumbers: .en,
            blocks: [
                .wordmark("HETZNER", tagline: "Hetzner Online GmbH"),
                .columns(left: [cast.alexName] + lisbonAddress, right: ["Hetzner Online GmbH", "Beispielstraße 1", "91710 Gunzenhausen", "Germany"]),
                .title("Invoice"),
                .fields([
                    Field("Invoice date", issued.enLong),
                    Field("Customer number", "K\(fake.reference(10))"),
                    Field("Billing period", "1 August 2026 – 31 August 2026"),
                    Field("Payment", "Credit card (VISA ending 4242), charged on \(Day(2026, 9, 3).enLong)"),
                ]),
                .heading("Cloud server and services, August 2026"),
                .table(Table([Column("Pos.", 0.08), Column("Description", 0.52), Column("Qty", 0.1, .right),
                              Column("Unit price", 0.15, .right), Column("Amount", 0.15, .right)],
                             rows: items.enumerated().map { ["\($0.offset + 1)", $0.element.0, "1", $0.element.1.eurEN, $0.element.1.eurEN] },
                             totals: [["", "Net total", "", "", net.eurEN], ["", "VAT 23% (Portugal)", "", "", vat.eurEN],
                                      ["", "Total", "", "", (net + vat).eurEN]])),
                .paragraph("Thank you for your business. The amount will be charged to the credit card stored in your account; no further action is required."),
                .note("Prices are monthly, billed in arrears. VAT is charged at the rate of the customer's country of residence (EU OSS scheme)."),
            ])
        return .filed(file, .en, .pdfText, type: .invoice,
                      correspondent: "Hetzner", date: issued,
                      titleContains: ["Cloud", "Server"], payload: .pdfText(document))
    }

    static func softwareLicence(cast: Cast, seed: UInt64) -> Fixture {
        let file = "en/43-jetbrains-license.pdf"
        var fake = Fake(seed: seed, salt: file)
        let ordered = Day(2026, 1, 10)
        let price = Money(299)
        let document = Document(
            info: DocumentInfo(title: "License Certificate – All Products Pack", author: "JetBrains s.r.o.", subject: "License certificate", created: ordered),
            accent: RGB(hex: 0x000000),
            footer: "JetBrains s.r.o. · Prague, Czech Republic · sales.jetbrains.com",
            pageNumbers: .en,
            blocks: [
                .wordmark("JetBrains", tagline: "JetBrains s.r.o."),
                .title("License Certificate"),
                .subtitle("All Products Pack – Personal annual subscription"),
                .fields([
                    Field("Licensed to", cast.alexName),
                    Field("Email", cast.alexEmail),
                    Field("License ID", fake.letters(10, from: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")),
                    Field("Order reference", "R\(ordered.iso.replacingOccurrences(of: "-", with: ""))-\(fake.reference(7))"),
                    Field("Order date", ordered.enUS),
                    Field("Subscription valid until", Day(2027, 1, 9).enUS),
                    Field("Quantity", "1"),
                    Field("Price", "\(price.eurEN) + VAT 23% = \((price + price.percent(23)).eurEN)"),
                ]),
                .heading("Products included"),
                .paragraph("IntelliJ IDEA Ultimate, PyCharm Professional, WebStorm, GoLand, CLion, Rider, RubyMine, PhpStorm, DataGrip, RustRover, DataSpell and dotUltimate."),
                .paragraph("This certificate confirms that the license listed above has been purchased under the JetBrains Toolbox Subscription Agreement for Individual Customers. The license is personal and may not be shared."),
                .paragraph("To activate your products, sign in with your JetBrains Account in the IDE (Help › Register) or use the license key available at account.jetbrains.com."),
                .note("After twelve months of continuous subscription you receive a perpetual fallback license for the version available at the start of the subscription."),
            ])
        return .filed(file, .en, .pdfText, type: .license,
                      correspondent: "JetBrains", date: ordered,
                      titleContains: ["All Products Pack"], payload: .pdfText(document))
    }

    // MARK: 44 Revolut screenshot

    static func transferScreenshot(cast: Cast, seed: UInt64) -> Fixture {
        let file = "en/44-revolut-transfer.png"
        var fake = Fake(seed: seed, salt: file)
        let sent = Day(2026, 9, 12)
        let screen = Screenshot(
            clock: "10:14", navigationTitle: "Transfer details", avatarInitials: "AS", amount: "-€1,250.00",
            counterparty: "To \(cast.alexName) · Wise", status: "Completed",
            rows: [
                Field("Date", "\(sent.enShort), 10:14"),
                Field("From", "EUR · Main account"),
                Field("To", cast.alexName),
                Field("Bank", "Wise Europe SA"),
                Field("IBAN", cast.alexWiseIBAN),
                Field("Reference", "Savings September"),
                Field("Fee", "€0.00"),
                Field("Transaction ID", "\(fake.hex(8))-\(fake.hex(4))-\(fake.hex(4))"),
            ],
            actions: ["Share receipt", "Repeat"],
            footnote: "Payment made with Revolut Bank UAB")
        return .filed(file, .en, .imageScreenshot, type: .receipt,
                      correspondent: "Revolut", date: sent,
                      titleContains: ["Transfer", "Wise"], identifiers: [.iban(cast.alexWiseIBAN)],
                      payload: .screenshot(screen))
    }

    // MARK: 45 TAP booking

    static func flightBooking(cast: Cast, seed: UInt64) -> Fixture {
        let file = "en/45-tap-booking.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 8, 15)
        let fare = Money(214)
        let taxes = Money(97, 46)
        let document = Document(
            info: DocumentInfo(title: "Booking confirmation and e-ticket receipt", author: "TAP Air Portugal", subject: "Electronic ticket", created: issued),
            accent: RGB(hex: 0x00833E),
            footer: "TAP Air Portugal · Transportes Aéreos Portugueses, S.A. · Edifício Exemplo, 1700-000 Lisboa · flytap.com",
            pageNumbers: .en,
            blocks: [
                .wordmark("TAP AIR PORTUGAL", tagline: "Transportes Aéreos Portugueses, S.A."),
                .title("Booking confirmation"),
                .subtitle("Electronic ticket receipt – Lisbon to Istanbul"),
                .fields([
                    Field("Booking reference", fake.letters(6)),
                    Field("Date of issue", issued.enShort),
                    Field("Issuing office", "TAP Air Portugal – flytap.com"),
                    Field("Passenger", "SAMPLE/ALEX MR"),
                    Field("Ticket number", "047 \(fake.reference(10))"),
                    Field("Frequent flyer", "TP \(fake.reference(9))"),
                ]),
                .heading("Itinerary"),
                .table(Table([Column("Flight", 0.12), Column("From", 0.22), Column("To", 0.22), Column("Date", 0.16),
                              Column("Dep.", 0.09), Column("Arr.", 0.09), Column("Class", 0.1)],
                             rows: [
                                ["TP1759", "Lisbon (LIS) T1", "Istanbul (IST)", "02 Oct 2026", "13:50", "20:35", "K"],
                                ["TP1760", "Istanbul (IST)", "Lisbon (LIS) T1", "09 Oct 2026", "22:05", "00:55+1", "K"],
                             ])),
                .fields([Field("Fare family", "Economy Classic – 1 checked bag of 23 kg, seat selection included")]),
                .heading("Payment"),
                .table(Table([Column("Item", 0.7), Column("Amount", 0.3, .right)],
                             rows: [["Base fare", "EUR \(fare.en)"], ["Taxes, fees and carrier charges", "EUR \(taxes.en)"]],
                             totals: [["Total paid (VISA ending 4242)", "EUR \((fare + taxes).en)"]])),
                .paragraph("Online check-in opens 36 hours before departure. Please present a passport valid for at least 150 days beyond your arrival in Türkiye."),
                .note("Carriage is subject to TAP's general conditions of carriage. Changes and refunds follow the rules of the fare purchased."),
            ])
        return .filed(file, .en, .pdfText, type: .ticket,
                      correspondent: "TAP", date: issued,
                      titleContains: ["Lisbon", "Istanbul"], payload: .pdfText(document))
    }

    // MARK: 46 passport data page (scan)

    static func passportScan(cast: Cast, seed: UInt64) -> Fixture {
        let file = "en/46-passport-scan.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2022, 3, 1)
        // The MRZ prints the number followed by its check digit; keep that 10-digit run from passing for an ИНН.
        var number = fake.reference(9)
        while Checksum.isValidRUINN(number + String(Checksum.mrzCheckDigit(number))) {
            number = fake.reference(9)
        }
        let navy = RGB(hex: 0x2B2F5A)
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat) -> CardElement {
            .text(text, x: x, y: y, size: 1.9, color: navy)
        }
        func value(_ text: String, _ x: CGFloat, _ y: CGFloat) -> CardElement {
            .text(text, x: x, y: y, size: 3.2, bold: true, color: .ink)
        }
        let birth = "900312"
        let expiry = "320301"
        let personal = String(repeating: "<", count: 14)
        let numberCheck = Checksum.mrzCheckDigit(number)
        let birthCheck = Checksum.mrzCheckDigit(birth)
        let expiryCheck = Checksum.mrzCheckDigit(expiry)
        let composite = "\(number)\(numberCheck)\(birth)\(birthCheck)\(expiry)\(expiryCheck)\(personal)0"
        let lineOne = "P<GBRSAMPLE<<ALEX".padding(toLength: 44, withPad: "<", startingAt: 0)
        let lineTwo = "\(number)\(numberCheck)GBR\(birth)\(birthCheck)M\(expiry)\(expiryCheck)\(personal)0\(Checksum.mrzCheckDigit(composite))"
        let card = Card(
            size: CGSize(width: 125, height: 88), cornerRadius: 3,
            background: [RGB(0.94, 0.89, 0.93), RGB(0.89, 0.91, 0.96)],
            securityPrint: RGB(0.58, 0.48, 0.70),
            elements: [
                .text("UNITED KINGDOM OF GREAT BRITAIN AND NORTHERN IRELAND", x: 5, y: 3, size: 2.6, bold: true, color: navy),
                .text("PASSPORT", x: 5, y: 7.5, size: 4.4, bold: true, color: navy),
                .portrait(CGRect(x: 5, y: 16, width: 32, height: 41)),
                .stamp("SPECIMEN", centre: CGPoint(x: 21, y: 36), size: 5.5, degrees: -32, color: RGB(0.80, 0.22, 0.22)),
                .signature(CGRect(x: 6, y: 60, width: 30, height: 8)),
                label("Type/Type", 42, 14), value("P", 42, 16.5),
                label("Code/Code", 58, 14), value("GBR", 58, 16.5),
                label("Passport No./Passeport No.", 80, 14), value(number, 80, 16.5),
                label("Surname/Nom (1)", 42, 22), value("SAMPLE", 42, 24.5),
                label("Given names/Prénoms (2)", 42, 29.5), value("ALEX", 42, 32),
                label("Nationality/Nationalité (3)", 42, 37), value("BRITISH CITIZEN", 42, 39.5),
                label("Date of birth/Date de naissance (4)", 42, 44.5), value("12 MAR /MARS 90", 42, 47),
                label("Sex/Sexe (5)", 100, 44.5), value("M", 100, 47),
                label("Place of birth/Lieu de naissance (6)", 42, 52), value("LONDON", 42, 54.5),
                label("Date of issue/Date de délivrance (7)", 42, 59.5), value("01 MAR /MARS 22", 42, 62),
                label("Authority/Autorité (8)", 94, 59.5), value("HMPO", 94, 62),
                label("Date of expiry/Date d'expiration (9)", 42, 67), value("01 MAR /MARS 32", 42, 69.5),
                .text(lineOne, x: 5, y: 76, size: 3.6, family: .mono),
                .text(lineTwo, x: 5, y: 81.5, size: 3.6, family: .mono),
            ])
        let info = DocumentInfo(title: "Passport", author: "HM Passport Office", subject: "Passport data page", created: issued)
        return .filed(file, .en, .pdfScan, type: .idDocument,
                      correspondent: "HM Passport Office", date: issued,
                      titleContains: ["Passport"],
                      acceptAlso: AcceptAlso(correspondent: ["HMPO"]), payload: .pdfScan(.card(card, info: info)))
    }

    // MARK: 47 AIMA appointment e-mail

    static func appointmentEmail(cast: Cast, seed: UInt64) -> Fixture {
        let file = "en/47-aima-appointment.eml"
        var fake = Fake(seed: seed, salt: file)
        let sent = DateTimeStamp(Day(2026, 3, 4), hour: 10, minute: 12, second: 44)
        let booking = "AG-2026-\(fake.reference(7))"
        let details: [(String, String)] = [
            ("Service", "Renewal of residence permit (Renovação de autorização de residência)"),
            ("Appointment date", "16 April 2026"),
            ("Time", "10:30"),
            ("Location", "Loja AIMA Lisboa – Atendimento Exemplo, Avenida Exemplo 20, 1050-000 Lisboa"),
            ("Booking reference", booking),
            ("Residence permit number", fake.letters(1) + fake.digitString(8)),
        ]
        let documents = [
            "your valid passport;",
            "your current residence permit card;",
            "proof of accommodation (lease contract or atestado de residência);",
            "proof of means of subsistence;",
            "your NIF and NISS numbers.",
        ]
        let intro = "Your appointment with AIMA – Agência para a Integração, Migrações e Asilo has been confirmed."
        let cancel = "If you cannot attend, cancel the appointment at least 48 hours in advance through the AIMA portal. Missed appointments can only be rescheduled after 30 days."
        let plain = (["Dear \(cast.alexName),", "", intro, ""]
            + details.map { "\($0.0): \($0.1)" }
            + ["", "Please bring:"] + documents.map { " - \($0)" }
            + ["", cancel, "", "This message was sent automatically. Please do not reply.", "",
               "AIMA, I.P.", "Agência para a Integração, Migrações e Asilo"]).joined(separator: "\n")
        let html = (["<html><body>", "<p>Dear \(cast.alexName),</p>", "<p>\(intro)</p>", "<table>"]
            + details.map { "<tr><td><b>\($0.0)</b></td><td>\($0.1)</td></tr>" }
            + ["</table>", "<p>Please bring:</p>", "<ul>"] + documents.map { "<li>\($0)</li>" }
            + ["</ul>", "<p>\(cancel)</p>", "<p>AIMA, I.P. – Agência para a Integração, Migrações e Asilo</p>", "</body></html>"])
            .joined(separator: "\n")
        let calendar = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//AIMA//Agendamentos//PT", "METHOD:PUBLISH", "BEGIN:VEVENT",
            "UID:\(booking)@aima.gov.pt", "DTSTAMP:20260304T101244Z", "DTSTART:20260416T093000Z", "DTEND:20260416T100000Z",
            "SUMMARY:AIMA – Renovação de autorização de residência", "LOCATION:Loja AIMA Lisboa", "END:VEVENT", "END:VCALENDAR", "",
        ].joined(separator: "\r\n")
        let email = Email(
            from: Mailbox(name: "AIMA – Agendamentos", address: "agendamentos@aima.gov.pt"),
            to: Mailbox(name: cast.alexName, address: cast.alexEmail),
            sent: sent,
            subject: "Confirmação de agendamento / Appointment confirmation – Renovação de autorização de residência",
            messageID: "20260304101244.\(fake.hex(12))@notificacoes.aima.gov.pt",
            plainBody: plain, htmlBody: html,
            attachment: Attachment(filename: "agendamento.ics", contentType: "text/calendar; charset=UTF-8; method=PUBLISH", content: calendar))
        return .filed(file, .en, .eml, type: .letter,
                      correspondent: "AIMA", date: sent.day,
                      titleContains: ["appointment", "residence"], payload: .email(email))
    }
}
