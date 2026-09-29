import CoreGraphics

/// Portuguese household documents of Maria Exemplo (Lisbon).
enum PortugueseFixtures {
    static func all(cast: Cast, seed: UInt64) -> [Fixture] {
        [
            edpInvoice(cast: cast, seed: seed),
            edpInvoiceScan(cast: cast, seed: seed),
            meoInvoice(cast: cast, seed: seed),
            irsModelo3(cast: cast, seed: seed),
            irsAssessment(cast: cast, seed: seed),
            nissProof(cast: cast, seed: seed),
            residenceCard(cast: cast, seed: seed),
            millenniumStatement(cast: cast, seed: seed),
            leaseContract(cast: cast, seed: seed),
            rentReceipt(cast: cast, seed: seed),
            labResults(cast: cast, seed: seed),
            healthPolicy(cast: cast, seed: seed),
            supermarketReceipt(cast: cast, seed: seed),
            plumberQuote(cast: cast, seed: seed),
            contributionStatus(cast: cast, seed: seed),
            pharmacyReceipt(cast: cast, seed: seed),
        ]
    }

    // MARK: Shared figures

    private static let edpAccent = RGB(hex: 0xE2231A)
    private static let atAccent = RGB(hex: 0x1F4E79)
    private static let socialSecurityAccent = RGB(hex: 0x00558C)
    private static let atFooter = "Autoridade Tributária e Aduaneira · Ministério das Finanças · Portal das Finanças · www.portaldasfinancas.gov.pt"
    static let julyBill = ElectricityBill(period: Day(2026, 7, 1), kilowattHours: 215)
    static let augustBill = ElectricityBill(period: Day(2026, 8, 1), kilowattHours: 238)
    static let meoBill = TelecomBill(packageNet: Money(40, 64), callsNet: Money(1, 18))
    static let monthlyRent = Money(950)
    static let irsDeclarationID = "2025-G7K2-M4P9Q1-06"
    static let serviceOffice = "3085 – Lisboa-8"

    /// EDP electricity charges for one month (simple tariff, 6.9 kVA), shared by the invoice and the bank debit.
    struct ElectricityBill {
        let period: Day
        let kilowattHours: Int
        var days: Int { period.endOfMonth.day }
        var power: Money { Money(cents: Int((Double(days) * 33.12).rounded())) }
        var energy: Money { Money(cents: Int((Double(kilowattHours) * 16.32).rounded())) }
        var consumptionTax: Money { Money(cents: Int((Double(kilowattHours) * 0.1).rounded(.toNearestOrAwayFromZero))) }
        var operatorFee: Money { Money(cents: 7) }
        var audiovisualFee: Money { Money(2, 85) }
        var reducedBase: Money { power + audiovisualFee }
        var standardBase: Money { energy + consumptionTax + operatorFee }
        var reducedVAT: Money { reducedBase.percent(6) }
        var standardVAT: Money { standardBase.percent(23) }
        var total: Money { reducedBase + reducedVAT + standardBase + standardVAT }
    }

    struct TelecomBill {
        let packageNet: Money
        let callsNet: Money
        var net: Money { packageNet + callsNet }
        var vat: Money { net.percent(23) }
        var total: Money { net + vat }
    }

    private static func customerBlock(_ cast: Cast) -> [String] {
        [cast.maria.name, cast.maria.street, cast.maria.postcode, "NIF \(cast.maria.nif)"]
    }

    // MARK: 01–02 EDP electricity invoices

    private static func edpDocument(cast: Cast, bill: ElectricityBill, issued: Day, due: Day, fake: inout Fake) -> Document {
        let invoiceNumber = "FT EDPC\(bill.period.year)/\(fake.reference(9))"
        let reference = fake.reference(9)
        let spacedReference = "\(reference.prefix(3)) \(reference.dropFirst(3).prefix(3)) \(reference.suffix(3))"
        let entity = "\(fake.int(20...29)) \(fake.digitString(3))"
        let cpe = "PT 0002 0000 \(fake.digitString(4)) \(fake.digitString(4)) \(fake.letters(2))"
        let reading = fake.int(18_000...32_000)
        let end = bill.period.endOfMonth
        let money: (Money) -> String = { $0.eurPT }
        return Document(
            info: DocumentInfo(title: "Fatura \(invoiceNumber)", author: "EDP Comercial", subject: "Fatura de eletricidade", created: issued),
            accent: edpAccent,
            footer: "\(cast.edp.name) · Sede: Avenida Exemplo 24, 1200-000 Lisboa · NIPC \(cast.edp.taxID)",
            pageNumbers: .pt,
            blocks: [
                .wordmark("edp", tagline: cast.edp.name),
                .columns(left: ["EDP Comercial", "Avenida Exemplo 24", "1200-000 Lisboa", "NIPC \(cast.edp.taxID)"],
                         right: customerBlock(cast)),
                .title("Fatura"),
                .subtitle("Fatura de eletricidade – \(bill.period.ptMonthYear)"),
                .fields([
                    Field("Fatura n.º", invoiceNumber),
                    Field("Data de emissão", issued.ptNumeric),
                    Field("Período de faturação", "\(bill.period.ptNumeric) a \(end.ptNumeric)"),
                    Field("Data limite de pagamento", due.ptNumeric),
                    Field("N.º de cliente", fake.reference(10)),
                    Field("CPE", cpe),
                    Field("Potência contratada", "6,9 kVA · Tarifa simples"),
                ]),
                .banner("Total a pagar: \(money(bill.total))"),
                .heading("Detalhe da fatura"),
                .table(Table([Column("Descrição", 0.46), Column("Quantidade", 0.16, .right),
                              Column("Preço unitário", 0.2, .right), Column("Valor", 0.18, .right)],
                             rows: [
                                ["Potência contratada 6,9 kVA", "\(bill.days) dias", "0,3312 €/dia", money(bill.power)],
                                ["Energia – eletricidade simples", "\(bill.kilowattHours) kWh", "0,1632 €/kWh", money(bill.energy)],
                                ["Imposto especial de consumo", "\(bill.kilowattHours) kWh", "0,0010 €/kWh", money(bill.consumptionTax)],
                                ["Taxa de exploração DGEG", "1 mês", "0,07 €", money(bill.operatorFee)],
                                ["Contribuição audiovisual", "1 mês", "2,85 €", money(bill.audiovisualFee)],
                                ["IVA a 6% sobre \(money(bill.reducedBase))", "", "", money(bill.reducedVAT)],
                                ["IVA a 23% sobre \(money(bill.standardBase))", "", "", money(bill.standardVAT)],
                             ],
                             totals: [["Total da fatura", "", "", money(bill.total)]])),
                .heading("Pagamento por Referência Multibanco"),
                .paragraph("Pode pagar esta fatura no Multibanco, no MB WAY ou no seu homebanking até \(due.ptNumeric), com os dados abaixo. Se aderiu ao débito direto, o valor será cobrado na data limite."),
                .fields([Field("Entidade", entity), Field("Referência", spacedReference), Field("Montante", money(bill.total))]),
                .heading("O seu consumo"),
                .paragraph("Leitura real em \(end.ptNumeric): \(reading) kWh. Consumo no período: \(bill.kilowattHours) kWh, uma média de \(String(format: "%.1f", Double(bill.kilowattHours) / Double(bill.days)).replacingOccurrences(of: ".", with: ",")) kWh por dia."),
                .note("Origem da eletricidade comercializada: renováveis 71,2%, gás natural 18,4%, cogeração 7,9%, outras 2,5%. Emissões específicas: 98 g CO2/kWh."),
                .note("Avarias: contacte o operador da rede de distribuição E-Redes. Reclamações: Livro de Reclamações eletrónico em www.livroreclamacoes.pt."),
            ])
    }

    static func edpInvoice(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/01-edp-fatura-2026-07.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 8, 5)
        let document = edpDocument(cast: cast, bill: julyBill, issued: issued, due: Day(2026, 8, 25), fake: &fake)
        return .filed(file, .pt, .pdfText, type: .invoice,
                      correspondent: "EDP", date: issued,
                      titleContains: ["eletricidade", "julho"],
                      identifiers: [.ptNIF(cast.maria.nif), .ptNIF(cast.edp.taxID)],
                      payload: .pdfText(document))
    }

    static func edpInvoiceScan(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/02-edp-fatura-2026-08-scan.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 9, 5)
        let document = edpDocument(cast: cast, bill: augustBill, issued: issued, due: Day(2026, 9, 25), fake: &fake)
        return .filed(file, .pt, .pdfScan, type: .invoice,
                      correspondent: "EDP", date: issued,
                      titleContains: ["eletricidade", "agosto"],
                      identifiers: [.ptNIF(cast.maria.nif), .ptNIF(cast.edp.taxID)],
                      payload: .pdfScan(.document(document)))
    }

    // MARK: 03 MEO

    static func meoInvoice(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/03-meo-fatura-2026-08.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 8, 10)
        let due = Day(2026, 8, 30)
        let period = Day(2026, 8, 1)
        let bill = meoBill
        let invoiceNumber = "FT 2026A1/\(fake.reference(7))"
        let document = Document(
            info: DocumentInfo(title: "Fatura MEO \(invoiceNumber)", author: "MEO", subject: "Fatura de serviços de comunicações", created: issued),
            accent: RGB(hex: 0x0087C8),
            footer: "\(cast.meo.name) · Sede: Avenida Exemplo 40, 1069-300 Lisboa · NIPC \(cast.meo.taxID) · Serviço de apoio: meo.pt/ajuda",
            pageNumbers: .pt,
            blocks: [
                .wordmark("MEO", tagline: cast.meo.name),
                .columns(left: ["MEO", "Avenida Exemplo 40", "1069-300 Lisboa", "NIPC \(cast.meo.taxID)"], right: customerBlock(cast)),
                .title("Fatura"),
                .subtitle("Serviços Fibra e TV – \(period.ptMonthYear)"),
                .fields([
                    Field("Fatura n.º", invoiceNumber),
                    Field("Data de emissão", issued.ptNumeric),
                    Field("Período de faturação", "\(period.ptNumeric) a \(period.endOfMonth.ptNumeric)"),
                    Field("Data limite de pagamento", due.ptNumeric),
                    Field("N.º de conta cliente", Fake.invalidNIF),
                    Field("Tarifário", "MEO Fibra 1 Gbps + TV + Voz"),
                ]),
                .banner("Valor a pagar: \(bill.total.eurPT)"),
                .heading("Resumo dos serviços"),
                .table(Table([Column("Serviço", 0.52), Column("Período", 0.28), Column("Valor s/ IVA", 0.2, .right)],
                             rows: [
                                ["Pacote Fibra 1 Gbps + TV + Voz", "01/08 a 31/08/2026", bill.packageNet.eurPT],
                                ["Aluguer de equipamento MEO Box 4K", "01/08 a 31/08/2026", Money.zero.eurPT],
                                ["Chamadas para redes móveis", "julho de 2026", bill.callsNet.eurPT],
                             ],
                             totals: [["Subtotal", "", bill.net.eurPT], ["IVA à taxa de 23%", "", bill.vat.eurPT],
                                      ["Total", "", bill.total.eurPT]])),
                .heading("Pagamento"),
                .paragraph("Esta fatura será paga por débito direto na conta PT50 **** **** **** **** 9015 4 na data limite de pagamento. Não é necessária qualquer ação da sua parte."),
                .paragraph("O detalhe das chamadas e a segunda via desta fatura estão disponíveis na Área de Cliente em meo.pt."),
                .note("Fatura processada por programa certificado n.º \(fake.int(1000...2999))/AT. Os valores incluem IVA à taxa legal em vigor."),
            ])
        return .filed(file, .pt, .pdfText, type: .invoice,
                      correspondent: "MEO", date: issued,
                      titleContains: ["Fibra", "agosto"],
                      identifiers: [.ptNIF(cast.maria.nif), .ptNIF(cast.meo.taxID)],
                      invalidIdentifiers: [.ptNIF(Fake.invalidNIF)],
                      payload: .pdfText(document))
    }

    // MARK: 04–05 Autoridade Tributária

    static func irsModelo3(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/04-at-irs-modelo3-2025.pdf"
        let received = Day(2026, 5, 20)
        let document = Document(
            info: DocumentInfo(title: "Comprovativo de entrega IRS Modelo 3 2025", author: "Autoridade Tributária e Aduaneira",
                               subject: "Declaração de rendimentos", created: received),
            accent: atAccent, footer: atFooter, pageNumbers: .pt,
            blocks: [
                .wordmark("Portal das Finanças", tagline: "Autoridade Tributária e Aduaneira"),
                .title("IRS – Declaração Modelo 3"),
                .subtitle("Comprovativo de entrega da declaração de rendimentos"),
                .fields([
                    Field("Ano dos rendimentos", "2025"),
                    Field("Identificação da declaração", irsDeclarationID),
                    Field("Data de receção", received.iso),
                    Field("Hora de receção", "14:32:10"),
                    Field("Serviço de Finanças", serviceOffice),
                    Field("Estado da declaração", "Certa – aguarda liquidação"),
                ]),
                .heading("Sujeitos passivos"),
                .fields([
                    Field("Sujeito passivo A", "\(cast.maria.nif) – \(cast.maria.name)"),
                    Field("Estado civil", "Solteiro"),
                    Field("Residência fiscal", "Continente"),
                ]),
                .heading("Anexos entregues"),
                .table(Table([Column("Anexo", 0.14), Column("Descrição", 0.62), Column("Quadros", 0.24)],
                             rows: [
                                ["Rosto", "Identificação do sujeito passivo e do agregado", "1 a 8"],
                                ["A", "Rendimentos do trabalho dependente", "4A, 4B"],
                                ["H", "Benefícios fiscais e deduções", "6C, 7D"],
                             ])),
                .heading("Resumo dos valores declarados"),
                .table(Table([Column("Rubrica", 0.72), Column("Valor", 0.28, .right)],
                             rows: [
                                ["Rendimentos brutos da categoria A", Money(42_350).eurPT],
                                ["Retenções na fonte de IRS", Money(7_422).eurPT],
                                ["Contribuições obrigatórias para a segurança social", Money(4_658, 50).eurPT],
                                ["Despesas gerais familiares (e-Fatura)", Money(250).eurPT],
                                ["Despesas de saúde (e-Fatura)", Money(212, 40).eurPT],
                                ["Encargos com imóveis – rendas de habitação permanente", Money(502, 5).eurPT],
                             ])),
                .paragraph("A declaração foi submetida através do Portal das Finanças e validada centralmente. Pode acompanhar a liquidação em IRS › Consultar Declaração."),
                .note("Este comprovativo não dispensa a consulta da nota de liquidação, que será disponibilizada no Portal das Finanças."),
            ])
        return .filed(file, .pt, .pdfText, type: .taxReturn,
                      correspondent: "Autoridade Tributária", date: received,
                      titleContains: ["Modelo 3", "2025"], identifiers: [.ptNIF(cast.maria.nif)],
                      payload: .pdfText(document))
    }

    static func irsAssessment(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/05-at-nota-liquidacao-2025.pdf"
        var fake = Fake(seed: seed, salt: file)
        let assessed = Day(2026, 6, 12)
        let rows: [(String, Money)] = [
            ("Rendimento global", Money(42_350)),
            ("Dedução específica", Money(4_658, 50)),
            ("Rendimento coletável", Money(37_691, 50)),
            ("Importância apurada", Money(11_187, 2)),
            ("Parcela a abater", Money(3_393, 48)),
            ("Coleta total", Money(7_793, 54)),
            ("Deduções à coleta", Money(783, 91)),
            ("Coleta líquida", Money(7_009, 63)),
            ("Retenções na fonte", Money(7_422)),
        ]
        let refund = Money(7_422) - Money(7_009, 63)
        let document = Document(
            info: DocumentInfo(title: "Demonstração de liquidação de IRS 2025", author: "Autoridade Tributária e Aduaneira",
                               subject: "Nota de liquidação", created: assessed),
            accent: atAccent, footer: atFooter, pageNumbers: .pt,
            blocks: [
                .wordmark("Finanças", tagline: "Autoridade Tributária e Aduaneira · Direção de Serviços do IRS"),
                .title("Demonstração de Liquidação de IRS"),
                .subtitle("Nota de liquidação – ano dos rendimentos 2025"),
                .fields([
                    Field("N.º da liquidação", "2026 \(fake.reference(10))"),
                    Field("Data da liquidação", assessed.iso),
                    Field("Identificação da declaração", irsDeclarationID),
                    Field("Sujeito passivo A", "\(cast.maria.nif) – \(cast.maria.name)"),
                    Field("Serviço de Finanças", serviceOffice),
                ]),
                .heading("Apuramento do imposto"),
                .table(Table([Column("Descrição", 0.7), Column("Valor", 0.3, .right)],
                             rows: rows.map { [$0.0, $0.1.eurPT] },
                             totals: [["Valor a reembolsar", refund.eurPT]])),
                .banner("Reembolso: \(refund.eurPT)"),
                .paragraph("O reembolso será efetuado por transferência bancária para o IBAN \(cast.maria.iban), indicado na declaração, dentro do prazo previsto no artigo 97.º do Código do IRS."),
                .fields([Field("Data prevista do reembolso", Day(2026, 6, 26).iso)]),
                .note("Desta liquidação pode ser apresentada reclamação graciosa no prazo de 120 dias ou impugnação judicial no prazo de 3 meses, contados do termo do prazo de pagamento voluntário."),
            ])
        return .filed(file, .pt, .pdfText, type: .taxAssessment,
                      correspondent: "Autoridade Tributária", date: assessed,
                      titleContains: ["liquidação", "2025"],
                      identifiers: [.ptNIF(cast.maria.nif), .iban(cast.maria.iban)], payload: .pdfText(document))
    }

    // MARK: 06 / 15 Segurança Social

    static func nissProof(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/06-ss-comprovativo-niss.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2024, 3, 12)
        let document = Document(
            info: DocumentInfo(title: "Comprovativo de NISS", author: "Instituto da Segurança Social, I.P.",
                               subject: "Número de Identificação de Segurança Social", created: issued),
            accent: socialSecurityAccent,
            footer: "Instituto da Segurança Social, I.P. · Avenida Exemplo 1, 1049-000 Lisboa · www.seg-social.pt",
            pageNumbers: .pt,
            blocks: [
                .wordmark("Segurança Social", tagline: "Instituto da Segurança Social, I.P."),
                .title("Comprovativo de Número de Identificação de Segurança Social"),
                .subtitle("NISS – pessoa singular"),
                .paragraph("Para os devidos efeitos, certifica-se que a pessoa abaixo identificada se encontra inscrita no sistema de segurança social, tendo-lhe sido atribuído o Número de Identificação de Segurança Social (NISS) indicado."),
                .fields([
                    Field("Nome", cast.maria.name),
                    Field("NISS", cast.mariaNISS),
                    Field("NIF", cast.maria.nif),
                    Field("Data de nascimento", cast.mariaBirthDate.ptNumeric),
                    Field("Nacionalidade", "Brasileira"),
                    Field("Data de inscrição", Day(2024, 3, 11).ptNumeric),
                    Field("Data de emissão", issued.ptNumeric),
                ]),
                .paragraph("O NISS deve ser comunicado à entidade empregadora e indicado em todos os contactos com a Segurança Social. Os seus dados podem ser consultados na Segurança Social Direta."),
                .note("Documento emitido eletronicamente pela Segurança Social Direta. Código de validação: \(fake.letters(4))-\(fake.letters(4))-\(fake.int(1000...9999))."),
            ])
        return .filed(file, .pt, .pdfText, type: .attestation,
                      correspondent: "Segurança Social", date: issued,
                      titleContains: ["NISS"], identifiers: [.ptNIF(cast.maria.nif)],
                      payload: .pdfText(document))
    }

    static func contributionStatus(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/15-ss-situacao-contributiva.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 3, 5)
        let document = Document(
            info: DocumentInfo(title: "Declaração de situação contributiva", author: "Instituto da Segurança Social, I.P.",
                               subject: "Situação contributiva", created: issued),
            accent: socialSecurityAccent,
            footer: "Instituto da Segurança Social, I.P. · Avenida Exemplo 1, 1049-000 Lisboa · www.seg-social.pt",
            pageNumbers: .pt,
            blocks: [
                .wordmark("Segurança Social", tagline: "Instituto da Segurança Social, I.P."),
                .title("Declaração de Situação Contributiva"),
                .paragraph("Para os efeitos previstos no artigo 214.º do Código dos Regimes Contributivos do Sistema Previdencial de Segurança Social, declara-se que o contribuinte abaixo identificado tem a sua situação contributiva regularizada perante a Segurança Social na presente data."),
                .fields([
                    Field("Nome", cast.maria.name),
                    Field("NISS", cast.mariaNISS),
                    Field("NIF", cast.maria.nif),
                    Field("Situação", "Regularizada"),
                    Field("Data de emissão", issued.ptNumeric),
                    Field("Válida até", Day(2026, 7, 5).ptNumeric),
                    Field("Código de acesso", "\(fake.letters(4))-\(fake.letters(4))-\(fake.letters(4))"),
                ]),
                .paragraph("A autenticidade desta declaração pode ser confirmada em www.seg-social.pt, opção Consultar declaração, com o NISS e o código de acesso indicados."),
                .note("Documento emitido através da Segurança Social Direta. Não carece de assinatura."),
            ])
        return .filed(file, .pt, .pdfText, type: .attestation,
                      correspondent: "Segurança Social", date: issued,
                      titleContains: ["situação contributiva"], identifiers: [.ptNIF(cast.maria.nif)],
                      payload: .pdfText(document))
    }

    // MARK: 07 AIMA residence card (photo)

    static func residenceCard(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/07-aima-titulo-residencia-frente.jpg"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2025, 2, 1)
        let navy = RGB(hex: 0x1B2A5C)
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat) -> CardElement {
            .text(text, x: x, y: y, size: 1.55, color: .muted)
        }
        func value(_ text: String, _ x: CGFloat, _ y: CGFloat) -> CardElement {
            .text(text, x: x, y: y, size: 2.5, bold: true, color: .ink)
        }
        let card = Card(
            size: CGSize(width: 85.6, height: 54), cornerRadius: 3.2,
            background: [RGB(0.84, 0.90, 0.95), RGB(0.94, 0.89, 0.93), RGB(0.87, 0.93, 0.88)],
            securityPrint: RGB(0.40, 0.52, 0.72),
            elements: [
                .text("PORTUGAL", x: 3.5, y: 2.6, size: 3.0, bold: true, color: navy),
                .text("TÍTULO DE RESIDÊNCIA", x: 26, y: 2.4, size: 3.4, bold: true, color: navy),
                .text("AUTORIZAÇÃO DE RESIDÊNCIA / RESIDENCE PERMIT", x: 26, y: 6.8, size: 1.8, color: navy),
                .portrait(CGRect(x: 3.5, y: 11, width: 20, height: 25)),
                .signature(CGRect(x: 4, y: 38, width: 18, height: 5)),
                label("APELIDO(S) / SURNAME", 26, 11), value("EXEMPLO", 26, 13),
                label("NOME(S) / GIVEN NAMES", 26, 17), value("MARIA", 26, 19),
                label("SEXO / SEX", 26, 23), value("F", 26, 25),
                label("NACIONALIDADE / NATIONALITY", 42, 23), value("BRA", 42, 25),
                label("DATA DE NASCIMENTO / DATE OF BIRTH", 26, 29), value(cast.mariaBirthDate.ptNumeric.replacingOccurrences(of: "/", with: " "), 26, 31),
                label("VÁLIDO ATÉ / DATE OF EXPIRY", 26, 35), value("01 02 2027", 26, 37),
                label("N.º DOCUMENTO / DOCUMENT NO.", 57, 35), value(fake.letters(1) + fake.digitString(8), 57, 37),
                label("TIPO / TYPE", 26, 41), value("TEMPORÁRIO", 26, 43),
                label("EMITIDO EM / DATE OF ISSUE", 57, 41), value("01 02 2025", 57, 43),
                .text("AIMA, I.P. – Agência para a Integração, Migrações e Asilo", x: 3.5, y: 49, size: 1.8, bold: true, color: navy),
            ])
        let photo = Photo(subject: .card(card), format: .jpeg,
                          taken: DateTimeStamp(Day(2025, 2, 3), hour: 18, minute: 22, second: 10))
        return .filed(file, .pt, .imagePhoto, type: .idDocument,
                      correspondent: "AIMA", date: issued,
                      titleContains: ["Título", "residência"],
                      payload: .photo(photo))
    }

    // MARK: 08 Millennium bcp statement

    static func millenniumStatement(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/08-millennium-extrato-2026-08.pdf"
        var fake = Fake(seed: seed, salt: file)
        let start = Day(2026, 8, 1)
        let end = start.endOfMonth
        let opening = fake.money(1_400...2_100)
        let movements: [(Int, String, Money)] = [
            (1, "TRF EXEMPLO CONSULTORIA ORDENADO", Money(2_184, 57)),
            (3, "COMPRA CONTINENTE BOM DIA LISBOA", -fake.money(18...45)),
            (5, "TRF P/ JOAO EXEMPLO RENDA SETEMBRO", -monthlyRent),
            (8, "PAG SERV EPAL AGUAS LIVRES", -fake.money(14...26)),
            (12, "LEVANTAMENTO ATM LISBOA", -Money(60)),
            (14, "COMPRA FARMACIA CENTRAL EXEMPLO", -fake.money(6...20)),
            (18, "COMPRA CP COMBOIOS DE PORTUGAL", -fake.money(8...25)),
            (25, "DD EDP COMERCIAL", -julyBill.total),
            (30, "DD MEO SERVICOS COMUNICACOES", -meoBill.total),
            (31, "COMISSAO MANUTENCAO DE CONTA", -Money(5, 20)),
            (31, "IMPOSTO DO SELO S/ COMISSAO", -Money(0, 21)),
        ]
        var balance = opening
        var rows: [[String]] = []
        var debits = Money.zero
        var credits = Money.zero
        for (day, description, amount) in movements {
            balance += amount
            let date = Day(2026, 8, day).ptShort
            if amount < .zero { debits -= amount } else { credits += amount }
            rows.append([date, date, description, amount < .zero ? (-amount).pt : "", amount < .zero ? "" : amount.pt, balance.pt])
        }
        let document = Document(
            info: DocumentInfo(title: "Extrato de conta agosto 2026", author: "Millennium bcp", subject: "Extrato de conta à ordem", created: end),
            accent: RGB(hex: 0xC8005A),
            footer: "\(cast.millennium.name) · Sociedade Aberta · Sede: Praça Exemplo 28, 4000-000 Porto · NIPC \(cast.millennium.taxID)",
            pageNumbers: .pt,
            blocks: [
                .wordmark("Millennium bcp", tagline: cast.millennium.name),
                .columns(left: ["Extrato n.º 8/2026", "Data de emissão: \(end.ptNumeric)", "Balcão: Lisboa Avenidas Novas"],
                         right: customerBlock(cast)),
                .title("Extrato de Conta à Ordem"),
                .subtitle("Extrato de conta – \(start.ptMonthYear)"),
                .fields([
                    Field("Conta à ordem n.º", "45 \(fake.digitString(8))"),
                    Field("IBAN", cast.maria.iban),
                    Field("BIC/SWIFT", "BCOMPTPL"),
                    Field("Titular", cast.maria.name),
                    Field("Período", "\(start.ptNumeric) a \(end.ptNumeric)"),
                ]),
                .heading("Movimentos"),
                .table(Table([Column("Data mov.", 0.11), Column("Data valor", 0.11), Column("Descrição", 0.42),
                              Column("Débito", 0.12, .right), Column("Crédito", 0.12, .right), Column("Saldo", 0.12, .right)],
                             rows: [["", "", "SALDO INICIAL", "", "", opening.pt]] + rows,
                             totals: [["", "", "TOTAIS E SALDO FINAL", debits.pt, credits.pt, balance.pt]])),
                .fields([
                    Field("Saldo inicial", opening.eurPT),
                    Field("Total a débito", debits.eurPT),
                    Field("Total a crédito", credits.eurPT),
                    Field("Saldo final em \(end.ptNumeric)", balance.eurPT),
                ]),
                .note("Os depósitos estão abrangidos pelo Fundo de Garantia de Depósitos até 100.000 € por depositante. Comunique qualquer divergência no prazo de 30 dias."),
            ])
        return .filed(file, .pt, .pdfText, type: .statement,
                      correspondent: "Millennium BCP", date: end,
                      titleContains: ["Extrato", "agosto"],
                      identifiers: [.ptNIF(cast.maria.nif), .iban(cast.maria.iban), .ptNIF(cast.millennium.taxID)],
                      payload: .pdfText(document))
    }

    // MARK: 09 Lease (DOCX) and 10 rent receipt

    static func leaseContract(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/09-contrato-arrendamento.docx"
        var fake = Fake(seed: seed, salt: file)
        let signed = Day(2025, 8, 25)
        let article = fake.int(1_000...4_999)
        let document = Document(
            info: DocumentInfo(title: "Contrato de arrendamento – Rua Exemplo 12", author: cast.joao.name,
                               subject: "Arrendamento urbano para habitação", created: signed),
            family: .serif, accent: .black,
            blocks: [
                .title("CONTRATO DE ARRENDAMENTO URBANO PARA FINS HABITACIONAIS", alignment: .center),
                .subtitle("com prazo certo", alignment: .center),
                .paragraph("Entre:"),
                .paragraph("PRIMEIRO OUTORGANTE (Senhorio): \(cast.joao.name), contribuinte fiscal n.º \(cast.joao.nif), residente na \(cast.joao.address);"),
                .paragraph("SEGUNDA OUTORGANTE (Arrendatária): \(cast.maria.name), contribuinte fiscal n.º \(cast.maria.nif), residente na \(cast.maria.address);"),
                .paragraph("é livremente e de boa-fé celebrado o presente contrato de arrendamento, que se rege pelas cláusulas seguintes e, no omisso, pelo Novo Regime do Arrendamento Urbano."),
                .heading("Cláusula Primeira – Objeto"),
                .paragraph("O Primeiro Outorgante é dono e legítimo proprietário da fração autónoma designada pela letra «F», correspondente ao terceiro andar esquerdo do prédio urbano sito na Rua Exemplo 12, 1000-001 Lisboa, inscrito na matriz predial urbana da freguesia de Arroios sob o artigo \(article), com licença de utilização emitida pela Câmara Municipal de Lisboa, que dá de arrendamento à Segunda Outorgante."),
                .heading("Cláusula Segunda – Prazo"),
                .paragraph("O arrendamento é celebrado pelo prazo de 3 (três) anos, com início em 1 de setembro de 2025 e termo em 31 de agosto de 2028, renovando-se automaticamente por períodos sucessivos de 3 anos, salvo oposição de qualquer das partes nos termos legais."),
                .heading("Cláusula Terceira – Renda"),
                .paragraph("A renda mensal é de \(monthlyRent.eurPT) (novecentos e cinquenta euros), a pagar até ao dia 8 do mês anterior àquele a que respeitar, por transferência bancária para o IBAN \(cast.joao.iban), de que o Senhorio é titular. O Senhorio emitirá o respetivo recibo de renda eletrónico no Portal das Finanças."),
                .heading("Cláusula Quarta – Caução"),
                .paragraph("Na data da assinatura a Arrendatária entrega ao Senhorio a quantia de \(Money(1_900).eurPT), correspondente a duas rendas, a título de caução, que será restituída no termo do contrato, deduzida de eventuais danos."),
                .heading("Cláusula Quinta – Fim"),
                .paragraph("O locado destina-se exclusivamente a habitação própria e permanente da Arrendatária, não lhe podendo ser dado outro uso nem ser subarrendado, total ou parcialmente, sem autorização escrita do Senhorio."),
                .heading("Cláusula Sexta – Despesas"),
                .paragraph("São encargo do Senhorio as despesas de condomínio e o IMI. São encargo da Arrendatária os consumos de eletricidade, água, gás e telecomunicações, cujos contratos celebrará em seu nome."),
                .heading("Cláusula Sétima – Obras"),
                .paragraph("A Arrendatária não pode fazer obras no locado sem autorização escrita do Senhorio, salvo as de conservação ordinária e as urgentes previstas na lei."),
                .heading("Cláusula Oitava – Comunicação às Finanças"),
                .paragraph("O Senhorio obriga-se a comunicar o presente contrato à Autoridade Tributária e Aduaneira e a liquidar o respetivo imposto do selo no prazo legal."),
                .paragraph("Feito em Lisboa, aos 25 de agosto de 2025, em dois exemplares de igual valor, ficando um na posse de cada outorgante."),
                .gap,
                .columns(left: ["O Senhorio", "", "______________________________", cast.joao.name],
                         right: ["A Arrendatária", "", "______________________________", cast.maria.name]),
            ])
        return .filed(file, .pt, .docx, type: .contract,
                      correspondent: "João Exemplo", date: signed,
                      titleContains: ["arrendamento"],
                      identifiers: [.ptNIF(cast.joao.nif), .ptNIF(cast.maria.nif), .iban(cast.joao.iban)],
                      payload: .docx(document))
    }

    static func rentReceipt(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/10-recibo-renda-2026-09.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 9, 5)
        let period = Day(2026, 9, 1)
        let document = Document(
            info: DocumentInfo(title: "Recibo de renda eletrónico n.º 13", author: cast.joao.name,
                               subject: "Recibo de renda", created: issued),
            accent: atAccent, footer: atFooter, pageNumbers: .pt,
            blocks: [
                .strong("Portal das Finanças · Arrendamento"),
                .title("Recibo de Renda Eletrónico n.º 13"),
                .subtitle("Referente à renda de \(period.ptMonthYear)"),
                .fields([
                    Field("Data de emissão", issued.iso),
                    Field("Código de verificação", "\(fake.letters(4))\(fake.digitString(4))\(fake.letters(4))"),
                ]),
                .heading("Locador"),
                .fields([Field("Nome", cast.joao.name), Field("NIF", cast.joao.nif)]),
                .heading("Locatário"),
                .fields([Field("Nome", cast.maria.name), Field("NIF", cast.maria.nif)]),
                .heading("Imóvel arrendado"),
                .fields([
                    Field("Morada", cast.maria.address),
                    Field("Artigo matricial", "U-\(fake.int(1_000...4_999)) · Fração F · Freguesia de Arroios"),
                    Field("Fim", "Habitação permanente"),
                ]),
                .heading("Pagamento"),
                .fields([
                    Field("Período a que respeita", "\(period.iso) a \(period.endOfMonth.iso)"),
                    Field("Importância recebida", monthlyRent.eurPT),
                    Field("Data do recebimento", Day(2026, 8, 5).iso),
                    Field("Retenção na fonte de IRS", Money.zero.eurPT),
                ]),
                .paragraph("O locador declara ter recebido do locatário a importância acima indicada, relativa à renda de setembro de 2026 do imóvel identificado."),
                .note("Recibo emitido pelo locador no Portal das Finanças nos termos do artigo 115.º do Código do IRS. Documento processado por computador."),
            ])
        return .filed(file, .pt, .pdfText, type: .receipt,
                      correspondent: "João Exemplo", date: issued,
                      titleContains: ["Renda", "setembro"],
                      identifiers: [.ptNIF(cast.joao.nif), .ptNIF(cast.maria.nif)], payload: .pdfText(document))
    }

    // MARK: 11 Unilabs, 12 Multicare

    static func labResults(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/11-unilabs-analises-2026-06.pdf"
        var fake = Fake(seed: seed, salt: file)
        let reported = Day(2026, 6, 18)
        func decimal(_ range: ClosedRange<Double>, digits: Int) -> String {
            String(format: "%.\(digits)f", fake.double(range)).replacingOccurrences(of: ".", with: ",")
        }
        let document = Document(
            info: DocumentInfo(title: "Relatório de análises clínicas", author: "Unilabs Portugal", subject: "Resultados laboratoriais", created: reported),
            accent: RGB(hex: 0x003C71),
            footer: "\(cast.unilabs.name) · Laboratório de Patologia Clínica · NIPC \(cast.unilabs.taxID) · www.unilabs.pt",
            pageNumbers: .pt,
            blocks: [
                .wordmark("Unilabs", tagline: "Análises Clínicas · Laboratório Lisboa Exemplo"),
                .title("Relatório de Análises Clínicas"),
                .fields([
                    Field("Utente", cast.maria.name),
                    Field("Data de nascimento", cast.mariaBirthDate.ptNumeric),
                    Field("N.º de utente SNS", cast.mariaSNSNumber),
                    Field("Requisição n.º", fake.reference(10)),
                    Field("Médico requisitante", "Dra. Ana Exemplo"),
                    Field("Data da colheita", Day(2026, 6, 15).ptNumeric),
                    Field("Data do relatório", reported.ptNumeric),
                ]),
                .heading("Hematologia – Hemograma"),
                .table(Table([Column("Análise", 0.4), Column("Resultado", 0.18, .right), Column("Unidades", 0.18),
                              Column("Valores de referência", 0.24)],
                             rows: [
                                ["Eritrócitos", decimal(4.1...4.9, digits: 2), "x10^12/L", "3,80 – 5,10"],
                                ["Hemoglobina", decimal(12.6...14.6, digits: 1), "g/dL", "12,0 – 15,5"],
                                ["Hematócrito", decimal(37...43, digits: 1), "%", "36,0 – 46,0"],
                                ["Leucócitos", decimal(4.8...8.2, digits: 1), "x10^9/L", "4,0 – 10,0"],
                                ["Plaquetas", "\(fake.int(190...320))", "x10^9/L", "150 – 400"],
                             ])),
                .heading("Bioquímica"),
                .table(Table([Column("Análise", 0.4), Column("Resultado", 0.18, .right), Column("Unidades", 0.18),
                              Column("Valores de referência", 0.24)],
                             rows: [
                                ["Glicose em jejum", "\(fake.int(78...98))", "mg/dL", "70 – 110"],
                                ["Colesterol total", "\(fake.int(192...214)) H", "mg/dL", "< 190"],
                                ["Colesterol HDL", "\(fake.int(52...66))", "mg/dL", "> 45"],
                                ["Triglicéridos", "\(fake.int(70...120))", "mg/dL", "< 150"],
                                ["Creatinina", decimal(0.62...0.88, digits: 2), "mg/dL", "0,51 – 0,95"],
                                ["TSH", decimal(1.1...2.6, digits: 2), "µUI/mL", "0,27 – 4,20"],
                             ])),
                .paragraph("Resultados assinalados com H encontram-se acima do intervalo de referência. A interpretação deve ser feita pelo médico assistente."),
                .note("Validado por: Dr. Rui Exemplo, Especialista em Patologia Clínica. Relatório emitido eletronicamente."),
            ])
        return .filed(file, .pt, .pdfText, type: .medicalReport,
                      correspondent: "Unilabs", date: reported,
                      titleContains: ["Análises", "Clínicas"], identifiers: [.ptNIF(cast.unilabs.taxID)],
                      payload: .pdfText(document))
    }

    static func healthPolicy(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/12-multicare-apolice.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2025, 12, 15)
        let monthly = Money(39)
        let document = Document(
            info: DocumentInfo(title: "Apólice de seguro de saúde – condições particulares", author: "Multicare",
                               subject: "Seguro de saúde", created: issued),
            accent: RGB(hex: 0x00968F),
            footer: "\(cast.multicare.name) · NIPC \(cast.multicare.taxID) · Entidade supervisionada pela Autoridade de Supervisão de Seguros e Fundos de Pensões",
            pageNumbers: .pt,
            blocks: [
                .wordmark("Multicare", tagline: cast.multicare.name),
                .title("Apólice de Seguro de Saúde"),
                .subtitle("Condições particulares"),
                .fields([
                    Field("Apólice n.º", fake.reference(10)),
                    Field("Tomador do seguro", cast.maria.name),
                    Field("NIF do tomador", cast.maria.nif),
                    Field("Morada", cast.maria.address),
                    Field("Data de emissão", issued.ptNumeric),
                    Field("Data de início", Day(2026, 1, 1).ptNumeric),
                    Field("Duração", "Anual, renovável automaticamente"),
                    Field("Fracionamento", "Mensal"),
                    Field("Prémio mensal", monthly.eurPT),
                    Field("Prémio total anual", Money(cents: monthly.cents * 12).eurPT),
                ]),
                .heading("Pessoas seguras"),
                .table(Table([Column("Nome", 0.45), Column("Data de nascimento", 0.3), Column("N.º de cartão", 0.25)],
                             rows: [[cast.maria.name, cast.mariaBirthDate.ptNumeric, fake.reference(12)]])),
                .heading("Coberturas e capitais"),
                .table(Table([Column("Cobertura", 0.46), Column("Capital", 0.2, .right), Column("Copagamento", 0.34, .right)],
                             rows: [
                                ["Hospitalização", Money(50_000).eurPT, "10% (mín. 100 €)"],
                                ["Ambulatório", Money(1_500).eurPT, "15 € por consulta"],
                                ["Parto", Money(2_500).eurPT, "10%"],
                                ["Estomatologia", Money(500).eurPT, "20%"],
                                ["Medicamentos", Money(250).eurPT, "40%"],
                             ])),
                .paragraph("Períodos de carência: 90 dias para ambulatório e hospitalização, 365 dias para parto. As doenças preexistentes à data de início estão excluídas, salvo declaração aceite pelo segurador."),
                .paragraph("O cartão Multicare será enviado para a morada do tomador. Pode consultar a rede de prestadores convencionados em www.multicare.pt."),
            ])
        return .filed(file, .pt, .pdfText, type: .policy,
                      correspondent: "Multicare", date: issued,
                      titleContains: ["Apólice", "Saúde"],
                      identifiers: [.ptNIF(cast.maria.nif), .ptNIF(cast.multicare.taxID)], payload: .pdfText(document))
    }

    // MARK: 13 Continente till receipt (JPEG), 16 pharmacy receipt (HEIC)

    static func supermarketReceipt(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/13-continente-talao.jpeg"
        var fake = Fake(seed: seed, salt: file)
        let bought = DateTimeStamp(Day(2026, 9, 14), hour: 18, minute: 42, second: 0, utcOffsetMinutes: 60)
        let items: [(String, Money, String)] = [
            ("PAO DE FORMA INTEGRAL", Money(1, 49), "A"),
            ("LEITE MEIO GORDO 1L X6", Money(4, 74), "A"),
            ("BANANA DA MADEIRA KG", fake.money(1.8...2.6), "A"),
            ("AZEITE VIRGEM EXTRA 750ML", Money(6, 99), "C"),
            ("IOGURTE NATURAL 4X125G", Money(1, 29), "A"),
            ("CAFE MOIDO 250G", Money(3, 79), "C"),
            ("DETERGENTE ROUPA 40D", Money(11, 99), "D"),
            ("AGUA MINERAL 6X1,5L", Money(2, 34), "A"),
        ]
        let total = items.reduce(Money.zero) { $0 + $1.1 }
        func vat(_ code: String, rate: Double) -> (base: Money, tax: Money) {
            let gross = items.filter { $0.2 == code }.reduce(Money.zero) { $0 + $1.1 }
            let base = Money(cents: Int((Double(gross.cents) / (1 + rate / 100)).rounded()))
            return (base, gross - base)
        }
        let (baseA, taxA) = vat("A", rate: 6)
        let (baseC, taxC) = vat("C", rate: 13)
        let (baseD, taxD) = vat("D", rate: 23)
        let receipt = Receipt(columns: 40, lines: [
            .centered("CONTINENTE", bold: true),
            .centered("Modelo Continente Hipermercados, S.A."),
            .centered("Continente Bom Dia Exemplo"),
            .centered("Rua Exemplo do Comercio 45"),
            .centered("1000-100 Lisboa"),
            .centered("NIF \(cast.continente.taxID)"),
            .blank,
            .centered("FATURA SIMPLIFICADA", bold: true),
            .text("FS 0231/\(fake.reference(6))"),
            .text("Data: \(bought.day.ptDashed)  Hora: \(bought.clock)"),
            .text("Contribuinte: \(cast.maria.nif)"),
            .divider,
        ] + items.map { .amount("\($0.0) \($0.2)", $0.1.pt) } + [
            .divider,
            .amount("TOTAL", total.pt, bold: true),
            .amount("MULTIBANCO", total.pt),
            .amount("TROCO", Money.zero.pt),
            .divider,
            .text("TAXA      BASE        IVA"),
            .text("A  6%  " + baseA.pt.padding(toLength: 10, withPad: " ", startingAt: 0) + "  " + taxA.pt),
            .text("C 13%  " + baseC.pt.padding(toLength: 10, withPad: " ", startingAt: 0) + "  " + taxC.pt),
            .text("D 23%  " + baseD.pt.padding(toLength: 10, withPad: " ", startingAt: 0) + "  " + taxD.pt),
            .divider,
            .text("Cartao Continente: **** \(fake.digitString(4))"),
            .amount("Saldo acumulado em cartao", Money(3, 45).pt),
            .text("N. artigos: \(items.count)"),
            .text("ATCUD: J\(fake.letters(7))-\(fake.int(1000...9999))"),
            .code,
            .centered("Obrigado pela sua visita!"),
            .centered("Processado por programa"),
            .centered("certificado n. \(fake.int(1000...2999))/AT"),
        ])
        let photo = Photo(subject: .receipt(receipt), format: .jpeg,
                          taken: DateTimeStamp(bought.day, hour: 18, minute: 55, second: 3, utcOffsetMinutes: 60))
        return .filed(file, .pt, .imagePhoto, type: .receipt,
                      correspondent: "Continente", date: bought.day,
                      titleContains: ["Fatura", "simplificada"], identifiers: [.ptNIF(cast.maria.nif), .ptNIF(cast.continente.taxID)], acceptAlso: AcceptAlso(docType: [.invoice]), payload: .photo(photo))
    }

    static func pharmacyReceipt(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/16-farmacia-fatura-recibo.heic"
        var fake = Fake(seed: seed, salt: file)
        let bought = DateTimeStamp(Day(2026, 6, 20), hour: 11, minute: 5, second: 0, utcOffsetMinutes: 60)
        let ibuprofen = Money(3, 15)
        let paracetamol = Money(2, 49)
        let copayment = Money(0, 87)
        let saline = Money(4, 20)
        let total = ibuprofen + paracetamol - copayment + saline
        let base = Money(cents: Int((Double(total.cents) / 1.06).rounded()))
        let receipt = Receipt(columns: 40, lines: [
            .centered("FARMACIA CENTRAL EXEMPLO", bold: true),
            .centered("Dir. Tecnica: Dra. Sofia Exemplo"),
            .centered("Rua Exemplo 30, 1000-002 Lisboa"),
            .centered("NIF \(cast.pharmacy.taxID)"),
            .blank,
            .centered("FATURA-RECIBO", bold: true),
            .text("FR 2026/\(fake.reference(5))"),
            .text("Data: \(bought.day.iso)  \(bought.clock)"),
            .text("Contribuinte: \(cast.maria.nif)"),
            .text("Receita n. \(fake.reference(10))\(fake.digitString(9))"),
            .divider,
            .amount("IBUPROFENO 400MG 20 COMP", ibuprofen.pt),
            .amount("PARACETAMOL 1000MG 18 COMP", paracetamol.pt),
            .amount("  Comparticipacao SNS", (-copayment).pt),
            .amount("SORO FISIOLOGICO 30X5ML", saline.pt),
            .divider,
            .amount("TOTAL", total.pt, bold: true),
            .amount("IVA 6% incluido", (total - base).pt),
            .amount("Pago: Cartao de debito", total.pt),
            .divider,
            .text("ATCUD: F\(fake.letters(7))-\(fake.int(100...999))"),
            .code,
            .centered("Obrigado. As melhoras!"),
        ])
        let photo = Photo(subject: .receipt(receipt), format: .heic,
                          taken: DateTimeStamp(bought.day, hour: 11, minute: 31, second: 2, utcOffsetMinutes: 60))
        return .filed(file, .pt, .imagePhoto, type: .receipt,
                      correspondent: "Farmácia Central Exemplo", date: bought.day,
                      titleContains: ["Fatura-recibo"], identifiers: [.ptNIF(cast.maria.nif), .ptNIF(cast.pharmacy.taxID)], acceptAlso: AcceptAlso(docType: [.invoice]), payload: .photo(photo))
    }

    // MARK: 14 plumber's quote (XLSX)

    static func plumberQuote(cast: Cast, seed: UInt64) -> Fixture {
        let file = "pt/14-orcamento-canalizador.xlsx"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 8, 15)
        let lines: [(String, Int, String, Money)] = [
            ("Substituição de autoclismo de embutir", 1, "un.", Money(185)),
            ("Tubagem multicamada 16 mm", 6, "m", Money(7, 80)),
            ("Torneira de segurança e ligações flexíveis", 2, "un.", Money(18, 50)),
            ("Substituição de sifão do lavatório", 1, "un.", Money(24, 90)),
            ("Mão de obra (canalizador)", 6, "h", fake.money(24...30)),
            ("Deslocação", 1, "un.", Money(20)),
        ]
        let firstLine = 13
        var rows: [[Cell]] = [
            [.text(cast.plumber.name, bold: true)],
            [.text("Rua do Exemplo 45, 2700-001 Amadora · NIF \(cast.plumber.taxID)")],
            [.text("Telefone 210 000 000 · geral@canalizacoes-exemplo.pt")],
            [],
            [.text("ORÇAMENTO N.º 2026/\(fake.int(60...120))", bold: true)],
            [.text("Data:"), .text(issued.ptNumeric)],
            [.text("Validade:"), .text("30 dias")],
            [.text("Cliente:"), .text(cast.maria.name)],
            [.text("NIF:"), .text(cast.maria.nif)],
            [.text("Local da obra:"), .text(cast.maria.address)],
            [.text("Assunto:"), .text("Reparação da casa de banho – autoclismo e canalização do lavatório")],
            [.text("Descrição", bold: true), .text("Qtd.", bold: true), .text("Unid.", bold: true),
             .text("Preço unit. (€)", bold: true), .text("Total (€)", bold: true)],
        ]
        var subtotal = Money.zero
        for (offset, line) in lines.enumerated() {
            let row = firstLine + offset
            let amount = line.3.times(Double(line.1))
            subtotal += amount
            rows.append([.text(line.0), .integer(line.1), .text(line.2), .money(line.3),
                         .formula("B\(row)*D\(row)", cached: amount)])
        }
        let lastLine = firstLine + lines.count - 1
        let subtotalRow = lastLine + 2
        let vat = subtotal.percent(23)
        rows.append([])
        rows.append([.text("Subtotal"), .empty, .empty, .empty, .formula("SUM(E\(firstLine):E\(lastLine))", cached: subtotal)])
        rows.append([.text("IVA"), .empty, .empty, .percent(23), .formula("E\(subtotalRow)*D\(subtotalRow + 1)", cached: vat)])
        rows.append([.text("TOTAL", bold: true), .empty, .empty, .empty,
                     .formula("E\(subtotalRow)+E\(subtotalRow + 1)", cached: subtotal + vat, bold: true)])
        rows.append([])
        rows.append([.text("Condições de pagamento: 50% na adjudicação, 50% na conclusão dos trabalhos.")])
        rows.append([.text("Prazo de execução: 2 dias úteis após adjudicação. Garantia dos trabalhos: 2 anos.")])
        let workbook = Workbook(title: "Orçamento reparação casa de banho", creator: "Canalizações Exemplo", created: issued,
                                sheets: [Sheet(name: "Orçamento", columnWidths: [48, 8, 8, 16, 14], rows: rows)])
        return .filed(file, .pt, .xlsx, type: .quote,
                      correspondent: "Canalizações Exemplo", date: issued,
                      titleContains: ["Orçamento", "casa de banho"],
                      identifiers: [.ptNIF(cast.plumber.taxID), .ptNIF(cast.maria.nif)],
                      payload: .xlsx(workbook))
    }
}
