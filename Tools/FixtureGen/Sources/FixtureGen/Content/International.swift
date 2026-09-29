import Foundation

/// Documents from many countries, in many languages and scripts, each of a different household: the app reads any of
/// them the same way, by its signals. Every fixture lists the labels it should get besides its type, sender and date.
enum InternationalFixtures {
    static func all(seed: UInt64) -> [Fixture] {
        [
            germanElectricity(seed: seed), germanTaxAssessment(seed: seed), frenchLease(seed: seed), frenchTaxNotice(seed: seed),
            spanishHomePolicy(seed: seed), mexicanElectricity(seed: seed), italianFine(seed: seed), dutchPayslip(seed: seed),
            polishPhoneInvoice(seed: seed), swedishDentistEmail(seed: seed), czechStudyConfirmation(seed: seed),
            ukrainianStatement(seed: seed), turkishPhoneInvoice(seed: seed), greekTaxAssessment(seed: seed),
            chineseEmploymentContract(seed: seed), japaneseElectricity(seed: seed), koreanHospitalReceipt(seed: seed),
            arabicSalaryCertificate(seed: seed), hindiRentReceipt(seed: seed), californiaRegistration(seed: seed),
            brazilianElectricity(seed: seed),
        ]
    }

    // MARK: 50 German electricity bill, 51 German tax assessment (scan)

    static func germanElectricity(seed: UInt64) -> Fixture {
        let file = "intl/50-swm-jahresabrechnung-strom-2025.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 1, 20)
        let due = Day(2026, 2, 10)
        let meter = "1ESY 1160 4478 21"
        let energy = Money(1_046, 18)
        let base = Money(163, 80)
        let net = energy + base
        let vat = net.percent(19)
        let paid = Money(1_297, 75)
        let balance = net + vat - paid
        let eur = { (money: Money) in money.grouped(thousands: ".", decimal: ",") + " €" }
        let document = Document(
            info: DocumentInfo(title: "Jahresabrechnung Strom 2025", author: "Stadtwerke München GmbH", subject: "Rechnung", created: issued),
            accent: RGB(hex: 0x0065A3),
            footer: "Stadtwerke München GmbH · Beispielweg 1 · 80999 München",
            blocks: [
                .wordmark("SWM", tagline: "Stadtwerke München GmbH"),
                .columns(left: ["Frau", "Anna Beispiel", "Musterstraße 5", "80331 München"],
                         right: ["Kundennummer KD-\(fake.reference(6))", "Vertragskonto 2003 \(fake.reference(4)) \(fake.reference(2))",
                                 "Rechnungsdatum \(issued.dayFirst("."))"]),
                .title("Jahresabrechnung Strom 2025"),
                .fields([
                    Field("Lieferstelle", "Musterstraße 5, 80331 München"),
                    Field("Zählernummer", meter),
                    Field("Abrechnungszeitraum", "01.01.2025 – 31.12.2025"),
                    Field("Verbrauch", "3.412 kWh"),
                ]),
                .table(Table([Column("Position", 0.6), Column("Menge", 0.2, .right), Column("Betrag", 0.2, .right)],
                             rows: [["Arbeitspreis 30,66 ct/kWh", "3.412 kWh", eur(energy)], ["Grundpreis 13,65 €/Monat", "12 Monate", eur(base)]],
                             totals: [["Nettobetrag", "", eur(net)], ["Umsatzsteuer 19 %", "", eur(vat)],
                                      ["Gesamtbetrag", "", eur(net + vat)], ["Abzüglich geleistete Abschläge", "", "-" + eur(paid)]])),
                .banner("Nachzahlung: \(eur(balance))"),
                .paragraph("Bitte überweisen Sie den Betrag von \(eur(balance)) bis zum \(due.dayFirst(".")) auf das unten genannte Konto. Ihr neuer monatlicher Abschlag beträgt ab März 2026 116,00 €."),
                .note("Diese Rechnung wurde maschinell erstellt und ist ohne Unterschrift gültig. Fragen zu Ihrer Rechnung? Telefon 0800 000 000."),
            ])
        return .filed(file, .de, .pdfText, type: .invoice, correspondent: "Stadtwerke München", date: issued,
                      titleContains: ["Strom", "Jahresabrechnung"], acceptAlso: AcceptAlso(docType: [.statement], correspondent: ["SWM"]),
                      labels: [.party: ["Anna Beispiel"], .object: [meter], .period: ["2025"], .deadline: [due.iso],
                               .amount: ["\(balance.decimal) EUR"], .jurisdiction: ["Germany"]],
                      payload: .pdfText(document))
    }

    static func germanTaxAssessment(seed: UInt64) -> Fixture {
        let file = "intl/51-finanzamt-bescheid-2025-scan.pdf"
        let issued = Day(2026, 6, 18)
        let due = Day(2026, 7, 21)
        let taxNumber = "143/220/61854"
        let assessed = Money(14_236)
        let withheld = Money(13_150)
        let balance = assessed - withheld
        let eur = { (money: Money) in money.grouped(thousands: ".", decimal: ",") + " €" }
        let document = Document(
            info: DocumentInfo(title: "", author: "", subject: "", created: issued),
            family: .serif, accent: .black,
            blocks: [
                .strong("Finanzamt München"),
                .paragraph("Beispielplatz 1, 80335 München"),
                .columns(left: ["Herrn und Frau", "Thomas und Anna Beispiel", "Musterstraße 5", "80331 München"],
                         right: ["Steuernummer \(taxNumber)", "Datum \(issued.dayFirst("."))"]),
                .title("Bescheid für 2025 über Einkommensteuer"),
                .paragraph("Festsetzung: Der Bescheid ist nach § 165 Abs. 1 AO teilweise vorläufig. Zusammenveranlagung."),
                .table(Table([Column("", 0.7), Column("Euro", 0.3, .right)],
                             rows: [["Zu versteuerndes Einkommen", "71.842,00"], ["Festgesetzte Einkommensteuer", eur(assessed)],
                                    ["Abzüglich Steuerabzug vom Lohn", eur(withheld)]],
                             totals: [["Verbleibende Beträge (Nachzahlung)", eur(balance)]])),
                .paragraph("Bitte zahlen Sie \(eur(balance)) spätestens am \(due.dayFirst("."))."),
                .note("Rechtsbehelfsbelehrung: Gegen diesen Bescheid ist der Einspruch zulässig. Er ist innerhalb eines Monats nach Bekanntgabe beim Finanzamt München einzulegen."),
            ])
        return .filed(file, .de, .pdfScan, type: .taxAssessment, correspondent: "Finanzamt", date: issued,
                      titleContains: ["Einkommensteuer", "Bescheid"],
                      labels: [.party: ["Anna Beispiel", "Thomas Beispiel"], .reference: [taxNumber], .period: ["2025"],
                               .deadline: [due.iso], .amount: ["\(balance.decimal) EUR"], .jurisdiction: ["Germany"]],
                      payload: .pdfScan(.document(document)))
    }

    // MARK: 52 French lease (DOCX), 53 French tax notice

    static func frenchLease(seed: UInt64) -> Fixture {
        let file = "intl/52-bail-habitation-lyon.docx"
        let signed = Day(2025, 8, 20)
        let rent = Money(850)
        let eur = { (money: Money) in money.grouped(thousands: " ", decimal: ",") + " €" }
        let document = Document(
            info: DocumentInfo(title: "Contrat de location – logement vide", author: "Claire Martin", subject: "Bail d'habitation", created: signed),
            family: .serif, accent: .black,
            blocks: [
                .title("CONTRAT DE LOCATION", alignment: .center),
                .subtitle("Bail d'habitation – logement vide (loi n° 89-462 du 6 juillet 1989)", alignment: .center),
                .heading("I. Désignation des parties"),
                .paragraph("Le présent contrat est conclu entre les soussignés : Madame Claire Martin, demeurant 3 place des Exemples, 69002 Lyon, désignée ci-après « le bailleur » ; et Monsieur Julien Exemple, désigné ci-après « le locataire »."),
                .heading("II. Objet du contrat"),
                .paragraph("Le présent contrat a pour objet la location d'un logement situé 12 rue des Exemples, 69003 Lyon, 2e étage, appartement de type T3 d'une surface habitable de 64 m², avec une cave n° 7."),
                .heading("III. Date de prise d'effet et durée du contrat"),
                .paragraph("Le contrat prend effet le 1er septembre 2025 pour une durée de trois ans, soit jusqu'au 31 août 2028."),
                .heading("IV. Conditions financières"),
                .paragraph("Le loyer mensuel est fixé à \(eur(rent)), hors charges. Les charges récupérables font l'objet d'une provision mensuelle de 90,00 €. Le loyer est payable d'avance le 5 de chaque mois."),
                .paragraph("Le dépôt de garantie est fixé à \(eur(rent)), soit un mois de loyer hors charges."),
                .heading("V. Clause résolutoire"),
                .paragraph("Le bail sera résilié de plein droit à défaut de paiement du loyer ou des charges, deux mois après un commandement de payer demeuré infructueux."),
                .gap,
                .paragraph("Fait à Lyon, le 20 août 2025, en deux exemplaires originaux."),
                .columns(left: ["Le bailleur", "", "______________________", "Claire Martin"], right: ["Le locataire", "", "______________________", "Julien Exemple"]),
            ])
        return .filed(file, .fr, .docx, type: .contract, correspondent: "Claire Martin", date: signed,
                      titleContains: ["location", "bail"],
                      labels: [.party: ["Julien Exemple"], .object: ["rue des Exemples"], .period: ["2025-09-01"],
                               .amount: ["\(rent.decimal) EUR"], .jurisdiction: ["France"]],
                      payload: .docx(document))
    }

    static func frenchTaxNotice(seed: UInt64) -> Fixture {
        let file = "intl/53-dgfip-avis-impot-2026.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 7, 24)
        let due = Day(2026, 9, 15)
        let tax = Money(1_482)
        let notice = "26 69 A \(fake.reference(6)) \(fake.reference(2))"
        let document = Document(
            info: DocumentInfo(title: "Avis d'impôt 2026", author: "DGFiP", subject: "Impôt sur les revenus 2025", created: issued),
            accent: RGB(hex: 0x000091),
            footer: "Direction générale des Finances publiques · impots.gouv.fr",
            blocks: [
                .wordmark("Finances publiques", tagline: "Direction générale des Finances publiques"),
                .columns(left: ["M. EXEMPLE JULIEN", "12 RUE DES EXEMPLES", "69003 LYON"],
                         right: ["Numéro fiscal 3 012 \(fake.reference(3)) \(fake.reference(3)) \(fake.reference(3))", "Référence de l'avis \(notice)",
                                 "Date d'établissement \(issued.dayFirst("/"))"]),
                .title("Avis d'impôt 2026"),
                .subtitle("Impôt sur les revenus de l'année 2025"),
                .table(Table([Column("Détail", 0.7), Column("Montant", 0.3, .right)],
                             rows: [["Revenu fiscal de référence", "38 410 €"], ["Nombre de parts", "1,00"],
                                    ["Impôt sur le revenu net", "3 902 €"], ["Prélèvement à la source déjà versé", "2 420 €"]],
                             totals: [["Reste à payer", "\(tax.whole(thousands: " ")) €"]])),
                .banner("Somme à payer : \(tax.whole(thousands: " ")) € avant le \(due.dayFirst("/"))"),
                .paragraph("Vous pouvez payer en ligne sur impots.gouv.fr ou par prélèvement. Une majoration de 10 % s'applique en cas de retard de paiement."),
            ])
        return .filed(file, .fr, .pdfText, type: .taxAssessment, correspondent: "DGFiP", date: issued,
                      titleContains: ["impôt", "revenus"],
                      acceptAlso: AcceptAlso(correspondent: ["Finances publiques"]),
                      labels: [.party: ["Julien Exemple"], .reference: [notice], .period: ["2025"], .deadline: [due.iso],
                               .amount: ["\(tax.decimal) EUR"], .jurisdiction: ["France"]],
                      payload: .pdfText(document))
    }

    // MARK: 54 Spanish home insurance, 55 Mexican electricity bill

    static func spanishHomePolicy(seed: UInt64) -> Fixture {
        let file = "intl/54-mapfre-poliza-hogar.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 2, 20)
        let policy = "061-2026-\(fake.reference(7))"
        let premium = Money(312, 45)
        let eur = { (money: Money) in money.grouped(thousands: ".", decimal: ",") + " €" }
        let document = Document(
            info: DocumentInfo(title: "Póliza Hogar", author: "MAPFRE España", subject: "Condiciones particulares", created: issued),
            accent: RGB(hex: 0xD81E05),
            footer: "MAPFRE España, Compañía de Seguros y Reaseguros, S.A. · Calle Ejemplo 1, 28000 Madrid",
            blocks: [
                .wordmark("MAPFRE", tagline: "Seguro de Hogar"),
                .title("Condiciones particulares"),
                .fields([
                    Field("Número de póliza", policy),
                    Field("Tomador y asegurado", "Lucía Ejemplo García"),
                    Field("Situación del riesgo", "Calle del Ejemplo 7, 3.º B, 28001 Madrid"),
                    Field("Efecto", "01/03/2026 a las 00:00 horas"),
                    Field("Vencimiento", "28/02/2027 a las 24:00 horas"),
                    Field("Fecha de emisión", issued.dayFirst("/")),
                ]),
                .table(Table([Column("Garantía", 0.7), Column("Suma asegurada", 0.3, .right)],
                             rows: [["Continente (edificio)", "180.000,00 €"], ["Contenido", "35.000,00 €"],
                                    ["Responsabilidad civil", "300.000,00 €"], ["Daños por agua", "Incluido"]])),
                .banner("Prima total anual: \(eur(premium))"),
                .paragraph("El recibo se cargará en la cuenta designada por el tomador. La póliza se prorroga tácitamente por períodos anuales salvo oposición notificada con un mes de antelación."),
                .note("Esta póliza se rige por la Ley 50/1980, de 8 de octubre, de Contrato de Seguro."),
            ])
        return .filed(file, .es, .pdfText, type: .policy, correspondent: "MAPFRE", date: issued,
                      titleContains: ["Hogar", "póliza"],
                      labels: [.party: ["Lucía Ejemplo"], .object: ["Calle del Ejemplo 7"], .reference: [policy],
                               .period: ["2026-03-01/2027-02-28"], .amount: ["\(premium.decimal) EUR"], .jurisdiction: ["Spain"]],
                      payload: .pdfText(document))
    }

    static func mexicanElectricity(seed: UInt64) -> Fixture {
        let file = "intl/55-cfe-recibo-luz-2026-07.pdf"
        let issued = Day(2026, 7, 16)
        let due = Day(2026, 7, 30)
        let service = "123 456 789 012"
        let total = Money(1_234)
        let document = Document(
            info: DocumentInfo(title: "Aviso-Recibo", author: "CFE Suministrador de Servicios Básicos", subject: "Recibo de luz", created: issued),
            accent: RGB(hex: 0x008E5A),
            footer: "CFE Suministrador de Servicios Básicos · Av. Ejemplo 1, 06600 Ciudad de México · cfe.mx",
            blocks: [
                .wordmark("CFE", tagline: "Comisión Federal de Electricidad"),
                .columns(left: ["ROBERTO MUESTRA LÓPEZ", "AV. EJEMPLO 245, COL. CENTRO", "44100 GUADALAJARA, JAL."],
                         right: ["No. de servicio \(service)", "Tarifa 1C", "Fecha de emisión \(issued.dayFirst("/"))"]),
                .title("Aviso-Recibo de energía eléctrica"),
                .fields([
                    Field("Periodo facturado", "15 MAY 26 – 15 JUL 26"),
                    Field("Consumo", "642 kWh (bimestral)"),
                    Field("Fecha límite de pago", "30 JUL 26"),
                ]),
                .table(Table([Column("Concepto", 0.7), Column("Importe", 0.3, .right)],
                             rows: [["Energía", "$1,063.79"], ["IVA 16%", "$170.21"]],
                             totals: [["Total a pagar", "$\(total.en) MXN"]])),
                .banner("Total a pagar: $\(total.en)"),
                .paragraph("Evite la suspensión del suministro de luz pagando antes de la fecha límite. Pague en línea, en tiendas de conveniencia o en su banco."),
            ])
        return .filed(file, .es, .pdfText, type: .invoice, correspondent: "CFE", date: issued,
                      titleContains: ["energía", "luz"],
                      acceptAlso: AcceptAlso(correspondent: ["Comisión Federal de Electricidad"]),
                      labels: [.party: ["Roberto Muestra"], .object: [service], .period: ["2026-05-15/2026-07-15"], .deadline: [due.iso],
                               .amount: ["\(total.decimal) MXN"], .jurisdiction: ["Mexico"]],
                      payload: .pdfText(document))
    }

    // MARK: 56 Italian traffic fine, 57 Dutch payslip

    static func italianFine(seed: UInt64) -> Fixture {
        let file = "intl/56-comune-milano-verbale.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 5, 12)
        let record = "V/2026/\(fake.reference(6))"
        let plate = "GX 482 KM"
        let reduced = Money(58, 10)
        let full = Money(83)
        let eur = { (money: Money) in "€ " + money.grouped(thousands: ".", decimal: ",") }
        let document = Document(
            info: DocumentInfo(title: "Verbale di accertamento", author: "Comune di Milano – Polizia Locale", subject: "Violazione al Codice della Strada", created: issued),
            accent: RGB(hex: 0xB0002B),
            footer: "Comune di Milano · Polizia Locale · Piazza Esempio 1, 20122 Milano",
            blocks: [
                .wordmark("Comune di Milano", tagline: "Polizia Locale – Ufficio Verbali"),
                .columns(left: ["Sig. Marco Esempio", "Via degli Esempi 9", "20121 Milano MI"], right: ["Verbale n. \(record)", "Data \(issued.dayFirst("/"))"]),
                .title("Verbale di accertamento di violazione"),
                .subtitle("al Codice della Strada (art. 7, commi 9 e 14 – accesso non autorizzato ad Area C)"),
                .fields([
                    Field("Veicolo", "autovettura Fiat Panda, targa \(plate)"),
                    Field("Luogo della violazione", "Via Ejemplo angolo Corso Esempio, Milano"),
                    Field("Data e ora", "28/04/2026, ore 09:14"),
                    Field("Proprietario", "Marco Esempio"),
                ]),
                .table(Table([Column("Pagamento", 0.7), Column("Importo", 0.3, .right)],
                             rows: [["Entro 5 giorni dalla notifica (riduzione del 30%)", eur(reduced)], ["Entro 60 giorni dalla notifica", eur(full)]])),
                .paragraph("Il pagamento può essere effettuato tramite PagoPA indicando il numero del verbale. Contro il presente verbale è ammesso ricorso al Prefetto entro 60 giorni o al Giudice di Pace entro 30 giorni dalla notifica."),
            ])
        return .filed(file, .it, .pdfText, type: .letter, correspondent: "Comune di Milano", date: issued,
                      titleContains: ["verbale", "violazione"],
                      acceptAlso: AcceptAlso(docType: [.legal, .invoice], correspondent: ["Polizia Locale"]),
                      labels: [.party: ["Marco Esempio"], .object: [plate], .reference: [record],
                               .amount: ["\(full.decimal) EUR|\(reduced.decimal) EUR"], .jurisdiction: ["Italy|Milan"]],
                      payload: .pdfText(document))
    }

    static func dutchPayslip(seed: UInt64) -> Fixture {
        let file = "intl/57-loonstrook-2026-06.pdf"
        var fake = Fake(seed: seed, salt: file)
        let paid = Day(2026, 6, 25)
        let gross = Money(4_650)
        let tax = Money(1_183, 57)
        let pension = Money(221, 25)
        let net = gross - tax - pension
        let eur = { (money: Money) in "€ " + money.grouped(thousands: ".", decimal: ",") }
        let document = Document(
            info: DocumentInfo(title: "Loonstrook juni 2026", author: "Voorbeeld Techniek B.V.", subject: "Loonstrook", created: paid),
            accent: RGB(hex: 0xF36C21),
            footer: "Voorbeeld Techniek B.V. · Keizersgracht 100 · 1015 AA Amsterdam · KvK \(fake.reference(8))",
            blocks: [
                .wordmark("Voorbeeld Techniek", tagline: "Voorbeeld Techniek B.V."),
                .title("Loonstrook"),
                .subtitle("Periode: juni 2026"),
                .columns(left: ["Sanne de Vries", "Prinsengracht 200", "1016 HB Amsterdam"],
                         right: ["Personeelsnummer \(fake.reference(5))", "Functie: Projectleider", "Datum uitbetaling \(paid.dayFirst("-"))"]),
                .table(Table([Column("Omschrijving", 0.7), Column("Bedrag", 0.3, .right)],
                             rows: [["Salaris", eur(gross)], ["Loonheffing", "-" + eur(tax)], ["Pensioenpremie werknemer", "-" + eur(pension)]],
                             totals: [["Netto salaris", eur(net)]])),
                .banner("Netto uit te betalen: \(eur(net))"),
                .note("Het bedrag wordt overgemaakt naar uw rekening. Bewaar deze loonstrook voor uw administratie."),
            ])
        return .filed(file, .nl, .pdfText, type: .payslip, correspondent: "Voorbeeld Techniek", date: paid,
                      titleContains: ["loonstrook", "juni"],
                      labels: [.party: ["Sanne de Vries"], .period: ["2026-06"], .amount: ["\(net.decimal) EUR"], .jurisdiction: ["Netherlands"]],
                      payload: .pdfText(document))
    }

    // MARK: 58 Polish phone invoice, 59 Swedish dentist e-mail, 60 Czech study confirmation (text)

    static func polishPhoneInvoice(seed: UInt64) -> Fixture {
        let file = "intl/58-orange-faktura-2026-05.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 6, 5)
        let due = Day(2026, 6, 19)
        let number = "F/\(fake.reference(5))/06/2026"
        let line = "512 345 678"
        let total = Money(89, 99)
        let pln = { (money: Money) in money.grouped(thousands: " ", decimal: ",") + " zł" }
        let document = Document(
            info: DocumentInfo(title: "Faktura VAT \(number)", author: "Orange Polska S.A.", subject: "Faktura", created: issued),
            accent: RGB(hex: 0xFF7900),
            footer: "Orange Polska S.A. · ul. Przykładowa 1, 00-001 Warszawa · NIP 526-\(fake.reference(3))-\(fake.reference(2))-\(fake.reference(2))",
            blocks: [
                .wordmark("orange", tagline: "Orange Polska S.A."),
                .columns(left: ["Katarzyna Przykładowa", "ul. Przykładowa 14 m. 3", "00-001 Warszawa"],
                         right: ["Faktura VAT nr \(number)", "Data wystawienia \(issued.dayFirst("."))", "Numer klienta \(fake.reference(8))"]),
                .title("Faktura VAT"),
                .fields([
                    Field("Okres rozliczeniowy", "01.05.2026 – 31.05.2026"),
                    Field("Numer telefonu", line),
                    Field("Termin płatności", due.dayFirst(".")),
                ]),
                .table(Table([Column("Usługa", 0.55), Column("Netto", 0.15, .right), Column("VAT", 0.15, .right), Column("Brutto", 0.15, .right)],
                             rows: [["Abonament Orange Flex 60 GB", "73,16", "16,83", "89,99"]],
                             totals: [["Razem do zapłaty", "", "", pln(total)]])),
                .banner("Do zapłaty: \(pln(total))"),
                .paragraph("Prosimy o terminową wpłatę na indywidualny rachunek wskazany poniżej. Po terminie płatności naliczamy odsetki ustawowe."),
            ])
        return .filed(file, .pl, .pdfText, type: .invoice, correspondent: "Orange", date: issued,
                      titleContains: ["faktura"],
                      labels: [.party: ["Katarzyna Przykładowa"], .object: [line], .reference: [number], .period: ["2026-05"],
                               .deadline: [due.iso], .amount: ["\(total.decimal) PLN"], .jurisdiction: ["Poland"]],
                      payload: .pdfText(document))
    }

    static func swedishDentistEmail(seed: UInt64) -> Fixture {
        let file = "intl/59-folktandvarden-bokning.eml"
        var fake = Fake(seed: seed, salt: file)
        let sent = DateTimeStamp(Day(2026, 9, 22), hour: 14, minute: 3, second: 18, utcOffsetMinutes: 120)
        let visit = Day(2026, 10, 14)
        let booking = "BK-\(fake.reference(6))"
        let details: [(String, String)] = [
            ("Behandling", "Tandläkarbesök: undersökning och tandrengöring"), ("Datum", "onsdag 14 oktober 2026"), ("Tid", "09:30"),
            ("Klinik", "Folktandvården Exempelgatan, Exempelgatan 12, 113 21 Stockholm"), ("Bokningsnummer", booking),
        ]
        let intro = "Tack för din bokning hos Folktandvården Stockholm. Här är din bokningsbekräftelse."
        let cancel = "Avboka senast 24 timmar innan besöket, annars debiteras en avgift på 600 kronor."
        let plain = (["Hej Erik Exempel,", "", intro, ""] + details.map { "\($0.0): \($0.1)" }
            + ["", cancel, "", "Välkommen!", "Folktandvården Stockholm"]).joined(separator: "\n")
        let html = (["<html><body>", "<p>Hej Erik Exempel,</p>", "<p>\(intro)</p>", "<table>"]
            + details.map { "<tr><td><b>\($0.0)</b></td><td>\($0.1)</td></tr>" }
            + ["</table>", "<p>\(cancel)</p>", "<p>Välkommen!<br>Folktandvården Stockholm</p>", "</body></html>"]).joined(separator: "\n")
        let calendar = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Folktandvarden//Bokning//SV", "METHOD:PUBLISH", "BEGIN:VEVENT",
            "UID:\(booking)@folktandvarden.example", "DTSTAMP:20260922T120318Z", "DTSTART:20261014T073000Z", "DTEND:20261014T081500Z",
            "SUMMARY:Tandläkarbesök – Folktandvården", "LOCATION:Exempelgatan 12, Stockholm", "END:VEVENT", "END:VCALENDAR", "",
        ].joined(separator: "\r\n")
        let email = Email(
            from: Mailbox(name: "Folktandvården Stockholm", address: "bokning@folktandvarden.example"),
            to: Mailbox(name: "Erik Exempel", address: "erik.exempel@example.com"),
            sent: sent, subject: "Bokningsbekräftelse – tandläkarbesök 14 oktober",
            messageID: "20260922140318.\(fake.hex(12))@folktandvarden.example",
            plainBody: plain, htmlBody: html,
            attachment: Attachment(filename: "besok.ics", contentType: "text/calendar; charset=UTF-8; method=PUBLISH", content: calendar))
        return .filed(file, .sv, .eml, type: .letter, correspondent: "Folktandvården", date: sent.day,
                      titleContains: ["bokning", "tandläkar"],
                      labels: [.party: ["Erik Exempel"], .reference: [booking], .deadline: [visit.iso]],
                      payload: .email(email))
    }

    static func czechStudyConfirmation(seed: UInt64) -> Fixture {
        let file = "intl/60-potvrzeni-o-studiu.txt"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 9, 24)
        let text = """
        UNIVERZITA KARLOVA
        Matematicko-fyzikální fakulta
        Studijní oddělení, Ke Karlovu 3, 121 16 Praha 2

        Č. j.: UKMFF/\(fake.reference(6))/2026

        POTVRZENÍ O STUDIU

        Potvrzujeme, že

        Tereza Příkladová, nar. 14. 3. 2004

        je v akademickém roce 2026/2027 studentkou 3. ročníku bakalářského studijního programu Informatika,
        forma studia prezenční. Studium bylo zahájeno dne 1. 10. 2024, předpokládané ukončení 30. 9. 2027.

        Potvrzení se vydává pro účely přídavku na dítě a slevy na dani.

        V Praze dne 24. 9. 2026

        Mgr. Jana Příkladná
        vedoucí studijního oddělení

        """
        return .filed(file, .cs, .text, type: .attestation, correspondent: "Univerzita Karlova", date: issued,
                      titleContains: ["studiu", "potvrzení"],
                      acceptAlso: AcceptAlso(docType: [.certificate], correspondent: ["Charles University"]),
                      encoding: .utf8,
                      labels: [.party: ["Tereza Příkladová"], .period: ["2026"], .jurisdiction: ["Czech|Czechia"]],
                      payload: .text(text, .utf8))
    }

    // MARK: 61 Ukrainian bank statement, 62 Turkish phone invoice, 63 Greek tax assessment

    static func ukrainianStatement(seed: UInt64) -> Fixture {
        let file = "intl/61-privatbank-vypyska-2026-07.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 8, 1)
        let iban = fake.iban(country: "UA", bban: "305299" + "0000026" + fake.digitString(12))
        let opening = Money(21_764, 12)
        let moves: [(String, String, Money)] = [
            ("03.07.2026", "Зарахування заробітної плати", Money(38_500)),
            ("05.07.2026", "Оплата оренди квартири", -Money(18_000)),
            ("12.07.2026", "Київстар, поповнення рахунку", -Money(250)),
            ("19.07.2026", "Сільпо, покупка", -Money(2_431, 72)),
            ("27.07.2026", "Київводоканал, комунальні послуги", -Money(15_064)),
        ]
        let closing = moves.reduce(opening) { $0 + $1.2 }
        let uah = { (money: Money) in money.grouped(thousands: " ", decimal: ",") + " грн" }
        let document = Document(
            info: DocumentInfo(title: "Виписка по рахунку", author: "АТ КБ «ПриватБанк»", subject: "Виписка", created: issued),
            accent: RGB(hex: 0x6CB33F),
            footer: "АТ КБ «ПриватБанк» · вул. Прикладна, 1, м. Київ, 01001 · privatbank.ua",
            blocks: [
                .wordmark("ПриватБанк", tagline: "АТ КБ «ПриватБанк»"),
                .title("Виписка по рахунку"),
                .fields([
                    Field("Клієнт", "Олена Прикладна"),
                    Field("Рахунок", iban),
                    Field("Період", "01.07.2026 – 31.07.2026"),
                    Field("Дата формування", issued.ruNumeric),
                ]),
                .table(Table([Column("Дата", 0.18), Column("Опис операції", 0.57), Column("Сума", 0.25, .right)],
                             rows: [["01.07.2026", "Вхідний залишок", uah(opening)]] + moves.map { [$0.0, $0.1, uah($0.2)] },
                             totals: [["31.07.2026", "Вихідний залишок", uah(closing)]])),
                .note("Виписка сформована автоматично та не потребує підпису і печатки банку."),
            ])
        return .filed(file, .uk, .pdfText, type: .statement, correspondent: "ПриватБанк", date: issued,
                      titleContains: ["виписка"], identifiers: [.iban(iban)],
                      acceptAlso: AcceptAlso(correspondent: ["PrivatBank"]),
                      labels: [.party: ["Олена Прикладна"], .object: [iban], .period: ["2026-07"],
                               .amount: ["\(closing.decimal) UAH"], .jurisdiction: ["Ukraine"]],
                      payload: .pdfText(document))
    }

    static func turkishPhoneInvoice(seed: UInt64) -> Fixture {
        let file = "intl/62-turkcell-fatura-2026-07.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 8, 3)
        let due = Day(2026, 8, 18)
        let number = "TC\(fake.letters(2))\(fake.reference(8))"
        let line = "0532 123 45 67"
        let total = Money(489, 90)
        let tl = { (money: Money) in money.grouped(thousands: ".", decimal: ",") + " TL" }
        let document = Document(
            info: DocumentInfo(title: "Fatura", author: "Turkcell İletişim Hizmetleri A.Ş.", subject: "Fatura", created: issued),
            accent: RGB(hex: 0x003A70),
            footer: "Turkcell İletişim Hizmetleri A.Ş. · Örnek Cad. No:1, 34000 İstanbul · turkcell.com.tr",
            blocks: [
                .wordmark("Turkcell", tagline: "Turkcell İletişim Hizmetleri A.Ş."),
                .columns(left: ["Mehmet Örnek", "Örnek Mah. Deneme Sok. No: 4/2", "06420 Çankaya/Ankara"],
                         right: ["Fatura No: \(number)", "Fatura Tarihi: \(issued.ruNumeric)", "Hat Numarası: \(line)"]),
                .title("Fatura"),
                .fields([
                    Field("Fatura dönemi", "Temmuz 2026"),
                    Field("Son ödeme tarihi", due.ruNumeric),
                ]),
                .table(Table([Column("Hizmet", 0.7), Column("Tutar", 0.3, .right)],
                             rows: [["Platinum 20 GB paket", "359,00 TL"], ["ÖİV %10", "35,90 TL"], ["KDV %20", "95,00 TL"]],
                             totals: [["Ödenecek tutar", tl(total)]])),
                .banner("Toplam: \(tl(total))"),
                .paragraph("Faturanızı son ödeme tarihine kadar Turkcell Hesabım uygulamasından veya bankanızdan ödeyebilirsiniz."),
            ])
        return .filed(file, .tr, .pdfText, type: .invoice, correspondent: "Turkcell", date: issued,
                      titleContains: ["fatura"],
                      labels: [.party: ["Mehmet Örnek"], .object: [line], .reference: [number], .period: ["2026-07"],
                               .deadline: [due.iso], .amount: ["\(total.decimal) TRY"], .jurisdiction: ["Turkey|Türkiye"]],
                      payload: .pdfText(document))
    }

    static func greekTaxAssessment(seed: UInt64) -> Fixture {
        let file = "intl/63-aade-ekkatharistiko-2025.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 7, 15)
        let due = Day(2026, 7, 31)
        let tax = Money(1_420)
        let eur = { (money: Money) in money.grouped(thousands: ".", decimal: ",") + " €" }
        let document = Document(
            info: DocumentInfo(title: "Πράξη Διοικητικού Προσδιορισμού Φόρου", author: "ΑΑΔΕ", subject: "Φόρος εισοδήματος", created: issued),
            accent: RGB(hex: 0x0D5EAF),
            footer: "Ανεξάρτητη Αρχή Δημοσίων Εσόδων · Οδός Παραδείγματος 1, 100 00 Αθήνα · aade.gr",
            blocks: [
                .wordmark("ΑΑΔΕ", tagline: "Ανεξάρτητη Αρχή Δημοσίων Εσόδων"),
                .title("Πράξη Διοικητικού Προσδιορισμού Φόρου Εισοδήματος"),
                .subtitle("Φορολογικό έτος 2025"),
                .fields([
                    Field("Υπόχρεος", "Γιώργος Παράδειγμα"),
                    Field("Αριθμός δήλωσης", fake.reference(8)),
                    Field("Ημερομηνία έκδοσης", issued.ruNumeric),
                ]),
                .table(Table([Column("Περιγραφή", 0.7), Column("Ποσό", 0.3, .right)],
                             rows: [["Φόρος εισοδήματος", "4.310,00 €"], ["Παρακρατηθείς φόρος", "2.890,00 €"]],
                             totals: [["Ποσό για καταβολή", eur(tax)]])),
                .paragraph("Το ποσό καταβάλλεται σε οκτώ μηνιαίες δόσεις. Η πρώτη δόση λήγει στις \(due.ruNumeric)."),
            ])
        return .filed(file, .el, .pdfText, type: .taxAssessment, correspondent: "ΑΑΔΕ", date: issued,
                      titleContains: ["Φόρου", "Εισοδήματος"],
                      acceptAlso: AcceptAlso(correspondent: ["AADE", "Αρχή Δημοσίων Εσόδων"]),
                      labels: [.party: ["Γιώργος Παράδειγμα"], .period: ["2025"], .deadline: [due.iso],
                               .amount: ["\(tax.decimal) EUR"], .jurisdiction: ["Greece"]],
                      payload: .pdfText(document))
    }

    // MARK: 64 Chinese employment contract (DOCX), 65 Japanese electricity bill, 66 Korean hospital receipt

    static func chineseEmploymentContract(seed: UInt64) -> Fixture {
        let file = "intl/64-laodong-hetong.docx"
        let signed = Day(2026, 3, 2)
        let salary = Money(25_000)
        let document = Document(
            info: DocumentInfo(title: "劳动合同", author: "上海示例科技有限公司", subject: "劳动合同", created: signed),
            family: .serif, accent: .black,
            blocks: [
                .title("劳动合同", alignment: .center),
                .paragraph("甲方（用人单位）：上海示例科技有限公司"),
                .paragraph("地址：上海市浦东新区示例路 88 号"),
                .paragraph("乙方（劳动者）：王小明"),
                .heading("第一条 合同期限"),
                .paragraph("本合同为固定期限劳动合同，期限自 2026年3月16日 起至 2029年3月15日 止，其中试用期三个月。"),
                .heading("第二条 工作内容和工作地点"),
                .paragraph("乙方同意在甲方软件研发部门担任高级工程师，工作地点为上海市。"),
                .heading("第三条 劳动报酬"),
                .paragraph("甲方每月 10 日以货币形式支付乙方工资，月工资为人民币 \(salary.whole(thousands: ",")) 元（税前）。"),
                .heading("第四条 社会保险"),
                .paragraph("甲乙双方按照国家和上海市的规定参加社会保险，缴纳社会保险费。"),
                .heading("第五条 争议处理"),
                .paragraph("双方因履行本合同发生争议，可以向上海市浦东新区劳动人事争议仲裁委员会申请仲裁。"),
                .gap,
                .columns(left: ["甲方（盖章）：上海示例科技有限公司", "签订日期：2026年3月2日"], right: ["乙方（签字）：王小明", "签订日期：2026年3月2日"]),
            ])
        return .filed(file, .zh, .docx, type: .contract, correspondent: "示例科技", date: signed,
                      titleContains: ["劳动合同"],
                      labels: [.party: ["王小明"], .period: ["2026-03-16/2029-03-15"], .amount: ["\(salary.decimal) CNY"],
                               .jurisdiction: ["China|Shanghai"]],
                      payload: .docx(document))
    }

    static func japaneseElectricity(seed: UInt64) -> Fixture {
        let file = "intl/65-tepco-denki-ryokin-2026-07.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 8, 5)
        let due = Day(2026, 8, 25)
        let total = Money(8_432)
        let document = Document(
            info: DocumentInfo(title: "電気料金のお知らせ", author: "東京電力エナジーパートナー株式会社", subject: "ご請求書", created: issued),
            accent: RGB(hex: 0xE60012),
            footer: "東京電力エナジーパートナー株式会社 〒100-0000 東京都千代田区例町1-1-1",
            blocks: [
                .wordmark("東京電力エナジーパートナー", tagline: "TEPCO"),
                .columns(left: ["山田 花子 様", "〒150-0001 東京都渋谷区神宮前1-2-3"],
                         right: ["お客さま番号 03-\(fake.reference(4))-\(fake.reference(4))-\(fake.reference(2))", "発行日 2026年8月5日"]),
                .title("電気料金のお知らせ（ご請求書）"),
                .fields([
                    Field("ご契約種別", "従量電灯B 30A"),
                    Field("ご使用期間", "2026年7月4日〜2026年8月3日（31日間）"),
                    Field("ご使用量", "312 kWh"),
                    Field("お支払期限", "2026年8月25日"),
                ]),
                .table(Table([Column("内訳", 0.7), Column("金額", 0.3, .right)],
                             rows: [["基本料金", "935円"], ["電力量料金", "7,968円"], ["再エネ発電賦課金", "1,092円"], ["燃料費等調整額", "-1,563円"]],
                             totals: [["ご請求金額（税込）", "\(total.whole(thousands: ","))円"]])),
                .banner("ご請求金額 \(total.whole(thousands: ","))円"),
                .paragraph("お支払期限までにお近くのコンビニエンスストアまたは金融機関でお支払いください。"),
            ])
        return .filed(file, .ja, .pdfText, type: .invoice, correspondent: "東京電力", date: issued,
                      titleContains: ["電気料金"],
                      acceptAlso: AcceptAlso(correspondent: ["TEPCO"]),
                      labels: [.party: ["山田 花子|山田花子"], .period: ["2026-07-04/2026-08-03"], .deadline: [due.iso],
                               .amount: ["\(total.decimal) JPY"], .jurisdiction: ["Japan"]],
                      payload: .pdfText(document))
    }

    static func koreanHospitalReceipt(seed: UInt64) -> Fixture {
        let file = "intl/66-snuh-jinryobi-yeongsujeung.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 9, 7)
        let total = Money(48_300)
        let document = Document(
            info: DocumentInfo(title: "진료비 영수증", author: "서울대학교병원", subject: "영수증", created: issued),
            accent: RGB(hex: 0x00508F),
            footer: "서울대학교병원 · 서울특별시 종로구 예시로 1 · 대표전화 02-000-0000",
            blocks: [
                .wordmark("서울대학교병원", tagline: "Seoul National University Hospital"),
                .title("진료비 영수증"),
                .fields([
                    Field("환자성명", "김민준"),
                    Field("등록번호", fake.reference(8)),
                    Field("진료기간", "2026년 9월 7일"),
                    Field("진료과", "내과 (외래)"),
                ]),
                .table(Table([Column("항목", 0.55), Column("급여 본인부담", 0.225, .right), Column("비급여", 0.225, .right)],
                             rows: [["진찰료", "11,200", "0"], ["검사료", "21,600", "0"], ["영상진단료", "0", "15,500"]],
                             totals: [["환자부담 총액", "", "\(total.whole(thousands: ","))원"]])),
                .paragraph("수납일자: 2026년 9월 7일 · 카드 결제"),
                .note("이 영수증은 소득세법에 따른 의료비 공제신청에 사용할 수 있습니다."),
            ])
        return .filed(file, .ko, .pdfText, type: .receipt, correspondent: "서울대학교병원", date: issued,
                      titleContains: ["영수증", "진료비"],
                      acceptAlso: AcceptAlso(correspondent: ["Seoul National University Hospital"]),
                      labels: [.party: ["김민준"], .amount: ["\(total.decimal) KRW"]],
                      payload: .pdfText(document))
    }

    // MARK: 67 Arabic salary certificate, 68 Hindi rent receipt (text), 69 Californian registration, 70 Brazilian bill

    static func arabicSalaryCertificate(seed: UInt64) -> Fixture {
        let file = "intl/67-shahadat-ratib.pdf"
        let issued = Day(2026, 4, 10)
        let salary = Money(18_500)
        let document = Document(
            info: DocumentInfo(title: "شهادة راتب", author: "شركة المثال للتجارة ذ.م.م", subject: "شهادة راتب", created: issued),
            accent: RGB(hex: 0x006C35),
            footer: "شركة المثال للتجارة ذ.م.م · شارع الشيخ زايد، دبي، الإمارات العربية المتحدة",
            blocks: [
                .wordmark("شركة المثال للتجارة", tagline: "ذ.م.م"),
                .paragraph("التاريخ: 10/04/2026"),
                .title("شهادة راتب", alignment: .center),
                .paragraph("إلى من يهمه الأمر،"),
                .paragraph("تشهد شركة المثال للتجارة ذ.م.م بأن السيد أحمد المثال، الجنسية: أردني، يعمل لدينا بوظيفة مدير مبيعات منذ 01/02/2022 وحتى تاريخه."),
                .paragraph("ويتقاضى راتباً شهرياً إجمالياً قدره \(salary.whole(thousands: ",")) درهم إماراتي (AED 18,500)."),
                .paragraph("وقد أعطيت له هذه الشهادة بناءً على طلبه دون أدنى مسؤولية على الشركة."),
                .gap,
                .paragraph("مدير الموارد البشرية"),
                .paragraph("سارة المثال"),
            ])
        return .filed(file, .ar, .pdfText, type: .attestation, correspondent: "المثال للتجارة", date: issued,
                      titleContains: ["شهادة راتب"],
                      acceptAlso: AcceptAlso(docType: [.certificate, .payslip]),
                      labels: [.party: ["أحمد المثال"], .amount: ["\(salary.decimal) AED"], .jurisdiction: ["United Arab Emirates|UAE|Dubai"]],
                      payload: .pdfText(document))
    }

    static func hindiRentReceipt(seed: UInt64) -> Fixture {
        let file = "intl/68-kiraya-rasid-2026-06.txt"
        let issued = Day(2026, 6, 5)
        let rent = Money(25_000)
        let text = """
        किराया रसीद

        रसीद संख्या: 06/2026
        दिनांक: 05/06/2026

        प्राप्त किया श्रीमती प्रिया नमूना से ₹ 25,000 (पच्चीस हज़ार रुपये मात्र) जून 2026 माह के किराये के रूप में,
        संपत्ति: फ़्लैट 12, उदाहरण मार्ग, लाजपत नगर, नई दिल्ली 110024 के लिए।

        भुगतान का माध्यम: बैंक हस्तांतरण (UPI)

        मकान मालिक: राजेश उदाहरण
        पैन: ABCPU1234F

        हस्ताक्षर: राजेश उदाहरण

        """
        return .filed(file, .hi, .text, type: .receipt, correspondent: "राजेश उदाहरण", date: issued,
                      titleContains: ["किराया", "रसीद"], encoding: .utf8,
                      labels: [.party: ["प्रिया नमूना"], .object: ["उदाहरण मार्ग"], .period: ["2026-06"], .amount: ["\(rent.decimal) INR"]],
                      payload: .text(text, .utf8))
    }

    static func californiaRegistration(seed: UInt64) -> Fixture {
        let file = "intl/69-dmv-registration-renewal.pdf"
        let issued = Day(2026, 8, 1)
        let due = Day(2026, 9, 15)
        let plate = "8ABC123"
        let total = Money(243)
        let document = Document(
            info: DocumentInfo(title: "Vehicle Registration Renewal Notice", author: "California DMV", subject: "Renewal notice", created: issued),
            accent: RGB(hex: 0x1D4F91),
            footer: "State of California · Department of Motor Vehicles · PO Box 000000, Sacramento, CA 95800 · dmv.ca.gov",
            blocks: [
                .wordmark("DMV", tagline: "California Department of Motor Vehicles"),
                .columns(left: ["JORDAN SAMPLE", "1234 EXAMPLE AVE APT 5", "OAKLAND CA 94612"], right: ["Notice date \(issued.enUS)", "License plate \(plate)"]),
                .title("Vehicle Registration Renewal Notice"),
                .fields([
                    Field("Vehicle", "2019 HONDA CIVIC"),
                    Field("VIN", "2HGFC2F59KH" + "504127"),
                    Field("Registration expires", due.enUS),
                    Field("Smog certification", "Not required this year"),
                ]),
                .table(Table([Column("Fee", 0.7), Column("Amount", 0.3, .right)],
                             rows: [["Registration fee", "$69.00"], ["Vehicle license fee", "$118.00"], ["County/district fees", "$56.00"]],
                             totals: [["Total amount due", "$\(total.en)"]])),
                .banner("Pay $\(total.en) by \(due.enUS)"),
                .paragraph("Renew online at dmv.ca.gov, by mail or at a DMV kiosk. Late fees apply if payment is received after the expiration date."),
            ])
        return .filed(file, .en, .pdfText, type: .invoice, correspondent: "DMV", date: issued,
                      titleContains: ["registration", "renewal"],
                      acceptAlso: AcceptAlso(docType: [.letter], correspondent: ["Department of Motor Vehicles"]),
                      labels: [.party: ["Jordan Sample"], .object: [plate], .deadline: [due.iso], .amount: ["\(total.decimal) USD"],
                               .jurisdiction: ["California|United States"]],
                      payload: .pdfText(document))
    }

    static func brazilianElectricity(seed: UInt64) -> Fixture {
        let file = "intl/70-enel-conta-energia-2026-06.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 6, 10)
        let due = Day(2026, 6, 25)
        let installation = fake.reference(8)
        let total = Money(287, 43)
        let brl = { (money: Money) in "R$ " + money.grouped(thousands: ".", decimal: ",") }
        let document = Document(
            info: DocumentInfo(title: "Conta de energia", author: "Enel Distribuição São Paulo", subject: "Conta de energia", created: issued),
            accent: RGB(hex: 0x0555FA),
            footer: "Enel Distribuição São Paulo · Av. Exemplo, 1 · São Paulo – SP · enel.com.br",
            pageNumbers: .pt,
            blocks: [
                .wordmark("enel", tagline: "Enel Distribuição São Paulo"),
                .columns(left: ["ANA EXEMPLO SOUZA", "RUA EXEMPLO, 450 – APTO 81", "PINHEIROS – SÃO PAULO – SP", "05422-000"],
                         right: ["Nº da instalação \(installation)", "CPF \(fake.reference(3)).\(fake.reference(3)).\(fake.reference(3))-\(fake.reference(2))",
                                 "Emissão \(issued.ptNumeric)"]),
                .title("Conta de energia elétrica"),
                .fields([
                    Field("Referência", "06/2026"),
                    Field("Leitura", "08/05/2026 a 08/06/2026 (31 dias)"),
                    Field("Consumo", "268 kWh"),
                    Field("Vencimento", due.ptNumeric),
                ]),
                .table(Table([Column("Descrição", 0.7), Column("Valor", 0.3, .right)],
                             rows: [["Consumo de energia", "R$ 224,18"], ["Bandeira tarifária amarela", "R$ 5,02"], ["Contribuição de iluminação pública", "R$ 18,70"],
                                    ["Tributos (ICMS/PIS/COFINS)", "R$ 39,53"]],
                             totals: [["Total a pagar", brl(total)]])),
                .banner("Total a pagar: \(brl(total)) · Vencimento \(due.ptNumeric)"),
                .paragraph("Pague com Pix ou boleto até a data de vencimento. Após o vencimento serão cobrados multa de 2% e juros de mora."),
            ])
        return .filed(file, .pt, .pdfText, type: .invoice, correspondent: "Enel", date: issued,
                      titleContains: ["energia"],
                      labels: [.party: ["Ana Exemplo Souza"], .object: [installation], .period: ["2026-06"], .deadline: [due.iso],
                               .amount: ["\(total.decimal) BRL"], .jurisdiction: ["Brazil|São Paulo"]],
                      payload: .pdfText(document))
    }
}
