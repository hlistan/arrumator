/// Two labels of one kind that look alike, with how many documents have each and the names of some, and whether they are
/// one label written two ways: what `arrumatorcli eval` has the model judge, and scores (docs/evaluation.md). Written by
/// hand, not drawn from the seed, as they are what the judge is measured by: typos, accents left out, a legal form, the
/// same number grouped otherwise, a plural; and two people a letter apart, a son beside his father, a woman's surname
/// beside a man's, two offices of one authority, two banks, two plates, two countries, a broad and a narrow topic. Every
/// label is in its kind's form, which `arrumatorcli eval` checks before it asks.
struct LabelPairCase: Decodable, Sendable {
    let kind: String
    let value: String
    let into: String
    let valueDocuments: Int
    let valueNames: [String]
    let intoDocuments: Int
    let intoNames: [String]
    let same: Bool
    /// Why, for whoever reads a judgement the model got wrong.
    let why: String
    /// Whether the pair is of a kind of difference the judge's prompt neither names nor shows, so its score measures how
    /// the model judges what it was not told of.
    let heldOut: Bool

    var json: JSON {
        .object([
            ("kind", .string(kind)), ("value", .string(value)), ("into", .string(into)),
            ("value_documents", .integer(UInt64(valueDocuments))), ("value_names", .array(valueNames.map(JSON.string))),
            ("into_documents", .integer(UInt64(intoDocuments))), ("into_names", .array(intoNames.map(JSON.string))),
            ("same", .bool(same)), ("why", .string(why)), ("held_out", .bool(heldOut)),
        ])
    }
}

enum LabelPairs {
    private static func pair(_ kind: String, _ value: String, _ valueNames: [String], _ into: String, _ intoNames: [String], same: Bool,
                             _ why: String, valueDocuments: Int? = nil, intoDocuments: Int? = nil, heldOut: Bool = false) -> LabelPairCase {
        LabelPairCase(kind: kind, value: value, into: into, valueDocuments: valueDocuments ?? valueNames.count, valueNames: valueNames,
                      intoDocuments: intoDocuments ?? intoNames.count, intoNames: intoNames, same: same, why: why, heldOut: heldOut)
    }

    static let all: [LabelPairCase] = [
        // One label written two ways.
        pair("sender", "EDP Comercail", ["2026-09-05 EDP Comercail - Fatura eletricidade agosto.pdf"],
             "EDP Comercial", ["2026-08-05 EDP Comercial - Fatura eletricidade julho.pdf", "2026-07-05 EDP Comercial - Fatura eletricidade junho.pdf"],
             same: true, "a typo", intoDocuments: 6),
        pair("sender", "Finanzamt Muenchen", ["2026-05-12 Finanzamt Muenchen - Einkommensteuerbescheid 2025.pdf"],
             "Finanzamt München", ["2025-05-20 Finanzamt München - Einkommensteuerbescheid 2024.pdf"], same: true, "ü written ue"),
        pair("sender", "ACME Ltd", ["2026-02-01 ACME Ltd - Invoice 2026-118.pdf"], "ACME", ["2026-01-03 ACME - Invoice 2026-004.pdf"],
             same: true, "a legal form left out", intoDocuments: 3),
        pair("sender", "ПАО Сбербанк", ["2026-04-01 ПАО Сбербанк - Выписка по счёту.pdf"], "Сбербанк", ["2026-03-01 Сбербанк - Выписка по счёту.pdf"],
             same: true, "a legal form left out, in Cyrillic", intoDocuments: 4),
        pair("sender", "Vodafone Portgal", ["2026-06-10 Vodafone Portgal - Fatura junho.pdf"],
             "Vodafone Portugal", ["2026-05-10 Vodafone Portugal - Fatura maio.pdf"], same: true, "a typo", intoDocuments: 5),
        pair("party", "Maria Fernanda Exmplo", ["2026-03-31 Recibo de vencimento março.pdf"],
             "Maria Fernanda Exemplo", ["2026-02-28 Recibo de vencimento fevereiro.pdf", "2026-07-05 EDP Comercial - Fatura eletricidade junho.pdf"],
             same: true, "a typo in a surname", intoDocuments: 9),
        pair("party", "Julien Exempel", ["2026-01-15 Assurance habitation - Avis d'échéance.pdf"],
             "Julien Exemple", ["2025-01-15 Assurance habitation - Avis d'échéance.pdf"], same: true, "two letters swapped"),
        pair("topic", "electricty", ["2026-09-05 EDP Comercail - Fatura eletricidade agosto.pdf"],
             "electricity", ["2026-08-05 EDP Comercial - Fatura eletricidade julho.pdf"], same: true, "a typo", intoDocuments: 12),
        pair("topic", "income taxes", ["2026-05-12 Finanzamt Muenchen - Einkommensteuerbescheid 2025.pdf"],
             "income tax", ["2025-05-20 Finanzamt München - Einkommensteuerbescheid 2024.pdf"], same: true, "a plural", intoDocuments: 4),
        pair("topic", "water suply", ["2026-04-20 Águas do Porto - Fatura água abril.pdf"],
             "water supply", ["2026-03-20 Águas do Porto - Fatura água março.pdf"], same: true, "a typo", intoDocuments: 3),
        pair("object", "car Peugot 208 AA-12-BB", ["2026-02-10 Seguro automóvel - Apólice renovada.pdf"],
             "car Peugeot 208 AA-12-BB", ["2025-02-10 Seguro automóvel - Apólice.pdf"], same: true, "a misspelt make, the same plate"),
        pair("object", "savings acount 0012345678", ["2026-06-30 Santander - Extrato junho.pdf"],
             "savings account 0012345678", ["2026-05-31 Santander - Extrato maio.pdf"], same: true, "a typo, the same number", intoDocuments: 5),
        pair("reference", "contract V2026532774", ["2026-03-01 EDP Comercial - Alteração de contrato.pdf"],
             "contract V/2026/532774", ["2026-01-10 EDP Comercial - Contrato de fornecimento.pdf"], same: true,
             "the same number, its slashes left out"),
        pair("reference", "order 20260451", ["2026-04-02 ACME - Delivery note.pdf"], "order 2026/0451", ["2026-04-01 ACME - Order confirmation.pdf"],
             same: true, "the same number, its slash left out"),
        pair("jurisdiction", "Portgal", ["2026-09-05 EDP Comercail - Fatura eletricidade agosto.pdf"],
             "Portugal", ["2026-08-05 EDP Comercial - Fatura eletricidade julho.pdf"], same: true, "a typo", intoDocuments: 30),
        pair("jurisdiction", "Germny", ["2026-05-12 Finanzamt Muenchen - Einkommensteuerbescheid 2025.pdf"],
             "Germany", ["2025-05-20 Finanzamt München - Einkommensteuerbescheid 2024.pdf"], same: true, "a typo", intoDocuments: 6),
        // Two labels.
        pair("party", "Mario Silva", ["2026-03-02 Contrato de arrendamento.pdf"], "Maria Silva",
             ["2026-07-05 EDP Comercial - Fatura eletricidade junho.pdf", "2026-02-28 Recibo de vencimento fevereiro.pdf"],
             same: false, "two first names, two people", intoDocuments: 7),
        pair("party", "Julie Exemple", ["2026-09-01 École - Inscription.pdf"], "Julien Exemple", ["2025-01-15 Assurance habitation - Avis d'échéance.pdf"],
             same: false, "Julie and Julien are two people"),
        pair("party", "Иван Петрова", ["2026-02-14 Справка о доходах.pdf"], "Иван Петров", ["2026-01-20 Договор аренды.pdf"],
             same: false, "a woman's surname beside a man's"),
        pair("party", "Pedro Almeida Junior", ["2026-06-01 Matrícula escolar.pdf"], "Pedro Almeida", ["2026-05-31 Recibo de vencimento maio.pdf"],
             same: false, "a son beside his father", intoDocuments: 8),
        pair("sender", "EDP Distribuição", ["2026-04-15 EDP Distribuição - Leitura do contador.pdf"],
             "EDP Comercial", ["2026-08-05 EDP Comercial - Fatura eletricidade julho.pdf"], same: false,
             "two companies of one group: the grid and the supplier", intoDocuments: 6),
        pair("sender", "Finanzamt Münster", ["2026-07-01 Finanzamt Münster - Grundsteuerbescheid.pdf"],
             "Finanzamt München", ["2025-05-20 Finanzamt München - Einkommensteuerbescheid 2024.pdf"], same: false, "two tax offices of two cities"),
        pair("sender", "Banco Sabadell", ["2026-03-31 Banco Sabadell - Extracto marzo.pdf"],
             "Banco Santander", ["2026-05-31 Santander - Extrato maio.pdf"], same: false, "two banks"),
        pair("sender", "Câmara Municipal de Loures", ["2026-02-20 Câmara Municipal de Loures - IMI.pdf"],
             "Câmara Municipal de Lisboa", ["2026-04-10 Câmara Municipal de Lisboa - Licença de obras.pdf"], same: false, "two municipalities"),
        pair("topic", "property tax", ["2026-02-20 Câmara Municipal de Loures - IMI.pdf"],
             "income tax", ["2025-05-20 Finanzamt München - Einkommensteuerbescheid 2024.pdf"], same: false, "two taxes sharing a word",
             intoDocuments: 4),
        pair("topic", "plumbing repair", ["2026-08-12 Canalizador - Orçamento.pdf"], "plumbing", ["2026-08-20 Canalizador - Fatura.pdf"],
             same: false, "a narrower topic beside the broad one"),
        pair("topic", "car insurance", ["2026-02-10 Seguro automóvel - Apólice renovada.pdf"],
             "home insurance", ["2026-01-15 Assurance habitation - Avis d'échéance.pdf"], same: false, "two kinds of insurance"),
        pair("object", "car AB-12-BB", ["2026-06-15 Inspeção periódica.pdf"], "car AA-12-BB", ["2025-02-10 Seguro automóvel - Apólice.pdf"],
             same: false, "two plates a letter apart"),
        pair("jurisdiction", "Austria", ["2026-03-03 Finanzamt Wien - Bescheid.pdf"], "Australia", ["2026-01-12 ATO - Notice of assessment.pdf"],
             same: false, "two countries"),
        pair("jurisdiction", "Guinea-Bissau", ["2026-05-05 Embaixada - Visto.pdf"], "Guinea", ["2026-04-04 Embassy - Visa.pdf"],
             same: false, "two countries"),
        // Held out: kinds of difference the prompt neither names nor shows.
        pair("sender", "Câmara Mun. de Lisboa", ["2026-06-02 Câmara Mun. de Lisboa - Aviso.pdf"],
             "Câmara Municipal de Lisboa", ["2026-04-10 Câmara Municipal de Lisboa - Licença de obras.pdf"], same: true,
             "a word abbreviated", intoDocuments: 3, heldOut: true),
        pair("sender", "Hospital St. John", ["2026-03-12 Hospital St. John - Discharge letter.pdf"],
             "Hospital Saint John", ["2026-03-10 Hospital Saint John - Appointment.pdf"], same: true, "Saint abbreviated", heldOut: true),
        pair("sender", "Agrupamento de Escolas da Benfica", ["2026-09-15 Agrupamento de Escolas - Matrícula.pdf"],
             "Agrupamento de Escolas de Benfica", ["2026-06-30 Agrupamento de Escolas - Avaliação.pdf"], same: true,
             "a small word written otherwise", intoDocuments: 2, heldOut: true),
        pair("sender", "Canal de Isabel III", ["2026-05-20 Canal de Isabel III - Factura agua.pdf"],
             "Canal de Isabel II", ["2026-04-20 Canal de Isabel II - Factura agua.pdf"], same: false,
             "a roman numeral that names another", heldOut: true),
        pair("party", "Aleksandr Volkov", ["2026-02-14 Autorização de residência - Requerimento.pdf"], "Alexandr Volkov",
             ["2026-01-09 Contrato de trabalho.pdf"], same: true, "one Russian name transliterated two ways", intoDocuments: 3, heldOut: true),
    ]
}
