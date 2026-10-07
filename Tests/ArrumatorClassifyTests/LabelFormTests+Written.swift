@testable import ArrumatorClassify
import ArrumatorCore
import Foundation
import Testing

/// What the prompt asks to be written otherwise, told by its form alone, is written as the document itself tells, at
/// once, and goes back to the model only where the document does not tell (QA 2026-10-05, READ-6: Fast's reading model
/// joined a sender to a party, wrote titles in capitals and said what references are in the document's own language,
/// and gave each again once told, which cost it a call each; the reviews of its fix found repairs that cut names and
/// misspelled titles where the document did not tell).
extension LabelFormTests {
    /// The model told, in this exchange, of the guesses about `subjects`.
    static func told(_ subjects: String...) -> SentBack {
        let sentBack = SentBack()
        sentBack.tell(subjects)
        return sentBack
    }

    /// Each title, in capitals, of a document that does not tell its small letters (`why`): it goes back once, and
    /// stands as given again.
    static func goesBackOnce(_ cases: [(title: String, text: String, language: String, why: String)]) throws {
        for (title, text, language, why) in cases {
            #expect(throws: GuessSentBack<ValidatedAnalysis>.self, "\(why) is not told by the document, so the title goes back") {
                try validate([.sender: [], .party: []], title: title, text: text, language: language)
            }
            let again = try validate([.sender: [], .party: []], title: title, text: text, language: language, sentBack: told("title"))
            #expect(again.title == title, "\(why): and stands as given again: \(again.notes)")
        }
    }

    /// An invoice whose sender and customer are printed side by side, as its text layer keeps them (`PDFPageText`).
    static let columns = "EDP Comercial – Comercialização de Energia, S.A.\nEDP Comercial\tMaria Exemplo\n"
        + "Avenida Exemplo 24\tRua Exemplo 12\nFatura n.º\tFT EDPC2026/926804564\nEsta fatura de eletricidade é de julho"

    @Test func aPartyJoinedToTheSendersNamePrintedBesideItIsWrittenAsPrinted() throws {
        let reading = try Self.validate([.party: ["EDP Comercial Maria Exemplo", "Maria Exemplo"]], text: Self.columns)
        #expect(reading.labels.values(.party) == ["Maria Exemplo"], "the party is written as printed, once, with no call to the model")
        #expect(reading.notes == ["parties: “EDP Comercial Maria Exemplo” joins a sender's name to the party's the document prints beside "
                                      + "it, written as the document tells: “Maria Exemplo”"])
        let reversed = try Self.validate([.sender: ["EDP"], .party: ["EDP - Maria Exemplo"]], text: "EDP\tMaria Exemplo")
        #expect(reversed.labels.values(.party) == ["Maria Exemplo"], "what joins them is no part of the party: \(reversed.notes)")
        let second = try Self.validate([.party: ["Maria Exemplo EDP Comercial"]], text: "Maria Exemplo\tEDP Comercial")
        #expect(second.labels.values(.party) == ["Maria Exemplo"], "the sender's cell may come second: \(second.notes)")
        let longer = try Self.validate([.sender: ["EDP Comercial Comercialização de Energia"], .party: ["EDP Comercial Maria Exemplo"]],
                                       text: Self.columns)
        #expect(longer.labels.values(.party) == ["Maria Exemplo"],
                "a cell that is the start of the sender's name, in more than one word, is the sender's: \(longer.notes)")
    }

    @Test(arguments: [
        ("EDP Comercial S.A.", "EDP Comercial", "EDP Comercial – Comercialização de Energia, S.A.", "the sender's own name, shortened"),
        ("Caixa Geral de Depósitos", "Caixa Geral de Aposentações", "Caixa Geral de Aposentações\nPago à Caixa Geral de\nDepósitos",
         "a name wrapped"),
        ("Maria Exemplo João Silva", "EDP Comercial", "EDP Comercial\nMaria Exemplo\tJoão Silva", "two cells, neither the sender's"),
        ("Ana Maria Santos", "Santos & Santos, Advogados", "Santos & Santos, Advogados\nNome\tAna Maria\tSantos",
         "a surname a sender's name begins with"),
        ("EDP Comercial Maria", "EDP Comercial", "EDP Comercial\tMaria", "a name that would be cut down to one word"),
        ("Maria EDP Comercial", "EDP Comercial", "Maria\tEDP Comercial", "a name that would be cut down to one word, before the sender's"),
    ])
    func aPartyTheDocumentDoesNotPrintBesideItsSenderIsNoJoin(_ party: String, sender: String, text: String, why: String) throws {
        let reading = try Self.validate([.sender: [sender], .party: [party]], text: text)
        #expect(reading.labels.values(.sender) == [sender], "the document writes its sender: \(reading.notes)")
        #expect(!reading.notes.contains { $0.hasPrefix("parties") } && reading.labels.values(.party) == [party], "\(why): \(reading.notes)")
    }

    @Test func aTitleInCapitalsIsWrittenAsTheDocumentWritesItsWords() throws {
        let reading = try Self.validate([:], title: "FATURA DE ELETRICIDADE")
        #expect(reading.title == "Fatura de eletricidade" && reading.notes == [
            "title: “FATURA DE ELETRICIDADE” is written in capitals, written as the document tells: “Fatura de eletricidade”",
        ], "a heading printed in capitals, copied as it is, is written as a sentence of the document's words: \(reading.notes)")
        #expect(try Self.validate([:], title: "Fatura de eletricidade").notes.isEmpty, "the same title as a sentence stands")

        let cases: [(title: String, text: String, language: String, sentence: String)] = [
            ("TÍTULO DE RESIDÊNCIA TEMPORÁRIO", "AIMA, I.P. - Agência para a Integração, Migrações e Asilo\n"
                + "Título de residência temporário emitido em Lisboa", "pt", "Título de residência temporário"),
            ("FATURA DA EDP", "EDP Comercial\nFatura da EDP de julho", "pt", "Fatura da EDP"),
            ("FATURA DE ELETRICIDADE", "FATURA n.º\t123\nFatura de eletricidade de julho\nEsta fatura de eletricidade é paga", "pt",
             "Fatura de eletricidade"),
            ("FATURA VODAFONE JULHO", "Pague em vodafone.pt/faturas\nFatura Vodafone julho disponível", "pt", "Fatura Vodafone julho"),
            ("İHTARNAME KİRA SÖZLEŞMESİ", "İhtarname kira sözleşmesi hakkındadır.", "tr", "İhtarname kira sözleşmesi"),
            ("DOĞALGAZ FATURASI", "Doğalgaz faturası ektedir.", "tr", "Doğalgaz faturası"),
            ("IJZERHANDEL FACTUUR", "IJzerhandel factuur van juli.", "nl", "IJzerhandel factuur"),
            ("ΣΥΜΒΟΛΑΙΟ ΜΙΣΘΩΣΗΣ", "Συμβόλαιο μίσθωσης υπογράφεται σήμερα.", "el", "Συμβόλαιο μίσθωσης"),
            ("ΤΙΜΟΛΟΓΙΟ ΜΑΪΟΥ", "Τιμολόγιο Μαΐου για το ρεύμα.", "el", "Τιμολόγιο Μαΐου"),
            ("ΌΡΟΙ ΧΡΉΣΗΣ", "Όροι χρήσης της υπηρεσίας.", "el", "Όροι χρήσης"),
            ("ZYCIORYS ZAWODOWY", "Życiorys zawodowy Jana Kowalskiego.", "pl", "Życiorys zawodowy"),
            ("ETE INDIEN", "Été indien annoncé.", "fr", "Été indien"),
            ("FINAL NOTICE", "Final notice of payment due.", "en", "Final notice"),
            ("TÍTULO DE RESIDÊNCIA", "TÍTULO DE RESIDÊNCIA / Residence permit\nTítulo de residência emitido", "pt", "Título de residência"),
            ("FATURA DE ÁGUA E SANEAMENTO", "Fatura de água e saneamento de julho", "pt", "Fatura de água e saneamento"),
            ("TAXE FONCIÈRE À PAYER", "Votre avis a été établi.\nTaxe foncière à payer : 1 234 €", "fr", "Taxe foncière à payer"),
            ("TAXE FONCIERE A PAYER", "Votre avis a été établi.\nTaxe foncière à payer : 1 234 €", "fr", "Taxe foncière à payer"),
            ("TAXE FONCIERE", "TAXE FONCIERE 2025 - avis d'imposition\nTaxe foncière due en octobre", "fr", "Taxe foncière"),
            ("COMPROBANTE DEL DEPÓSITO", "El cliente depositó el importe\nComprobante del depósito realizado", "es", "Comprobante del depósito"),
            ("ENVÍO DOCUMENTOS", "Envió documentos ayer.\nEnvío documentos adjuntos", "es", "Envío documentos"),
            ("DOGALGAZ FATURASI İSTANBUL", "Doğalgaz faturası İstanbul ektedir.", "tr", "Doğalgaz faturası İstanbul"),
            ("FATURA EDP", "Fatura EDP de julho\npague a FATURA EDP hoje", "pt", "Fatura EDP"),
            ("EDP COMERCIAL S.A. LISBOA", "Esta fatura é da EDP Comercial S.A. Lisboa, paga em agosto", "pt", "EDP Comercial S.A. Lisboa"),
            ("CERTIFICADO DE VACINAÇÃO COVID-19", "Certificado de vacinação COVID-19", "pt", "Certificado de vacinação COVID-19"),
            ("SEGURO AUTOMÓVEL AA-12-BB", "Seguro automóvel AA-12-BB válido até 2027", "pt", "Seguro automóvel AA-12-BB"),
            ("RELATÓRIO Q3 2025", "Relatório Q3 2025 da empresa", "pt", "Relatório Q3 2025"),
            ("RELATÓRIO Q3 2025", "Relatório: Q3 2025 da empresa", "pt", "Relatório Q3 2025"),
            ("SEGURO AUTOMÓVEL AA-12-BB", "Seguro automóvel: AA-12-BB válido até 2027", "pt", "Seguro automóvel AA-12-BB"),
            ("RECIBO DE VENCIMENTO JULHO 2026", "Recibo de vencimento julho/2026", "pt", "Recibo de vencimento julho 2026"),
        ]
        for (title, text, language, sentence) in cases {
            let reading = try Self.validate([.sender: [], .party: []], title: title, text: text, language: language)
            #expect(reading.title == sentence, "each word as the document writes it, in its own language: \(reading.notes)")
        }
    }

    @Test func aTitleTheDocumentDoesNotTellTheSmallLettersOfIsNotWrittenAnew() throws {
        let card = "PORTUGAL\nTÍTULO DE RESIDÊNCIA\nAIMA, I.P. - Agência para a Integração, Migrações e Asilo\nEmitido em Lisboa"
        let sent = #expect(throws: GuessSentBack<ValidatedAnalysis>.self, "a card printed in capitals") {
            try Self.validate([.sender: [], .party: []], title: "TÍTULO DE RESIDÊNCIA", text: card)
        }
        #expect(sent?.problems == ["title: “TÍTULO DE RESIDÊNCIA” is written in capitals; write it as a sentence is written, with names as "
                                       + "the document writes them"], "goes back with no example the document does not bear out")
        let again = try Self.validate([.sender: [], .party: []], title: "TÍTULO DE RESIDÊNCIA", text: card, sentBack: Self.told("title"))
        #expect(again.title == "TÍTULO DE RESIDÊNCIA", "and stands as given again, as only the document could say its small letters")
        let unknown: [(title: String, text: String, language: String, why: String)] = [
            ("FATURA NOS TV", "NOS Comunicações, S.A.\nEsta fatura do serviço TV paga-se nos termos do contrato", "pt", "words written in no row"),
            ("ENVÍO DOCUMENTOS", "Envió documentos ayer.", "es", "the words with other accents"),
            ("IHTARNAME KIRA", "İhtarname kira hakkındadır.", "tr", "a dotted İ where the title has I"),
            ("FATURA EDP", "EDP Comercial\nFATURA n.º FT 2026/1\nTotal a pagar 54,21 €", "pt", "a heading beside an abbreviation's letter"),
            ("FATTURA IVA", "Rossi S.r.l FATTURA\nImporto IVA incluso", "it", "a heading beside an abbreviation's last letter"),
            ("FATTURA ENEL ENERGIA S.P.A.", "Fattura Enel Energia S.p.A.", "it", "a capital beside an abbreviation's letters alone"),
            ("COMPRA EBAY UK", "Compra eBay UK", "pt", "a capital beside a name with a capital inside"),
            ("FATURA DE ÁGUA E LUZ", "A fatura é de água, de luz", "pt", "words written in no row"),
            ("FATURA DE ELETRICIDADE", "Fatura de\teletricidade de julho", "pt", "words a tab parts"),
            ("FATURA DE ELETRICIDADE", "Esta fatura de eletricidade é de julho", "pt", "words a sentence begins with no capital"),
            ("FINAL NOTICE", "This is the ﬁnal notice.", "en", "a word begun with a ligature, small"),
            ("IPHONE 15 PRO", "O iPhone 15 Pro foi comprado em julho", "pt", "a name begun with a small letter"),
            ("TAXE FONCIERE A PAYER", "Taxe foncière à payer\nTaxe fonciere a payer", "fr", "words spelled two ways"),
            ("CAIXA GERAL DE DEPÓSITOS", "Caixa geral de depósitos\nCaixa Geral de Depósitos, S.A.", "pt", "a name spelled two ways"),
            ("FATURA DE ELETRICIDADE", "FATURA 2026/07 – Período de faturação de eletricidade", "pt", "a heading's words, written so alone"),
            ("TERMOS E CONDIÇÕES", "TERMOS E CONDIÇÕES – leia com atenção", "pt", "a heading's words beside small ones"),
            ("NOTA DE CRÉDITO", "NOTA DE CRÉDITO n.º 12/2025", "pt", "a heading's words beside a number"),
            ("CONSUMO EM KWH", "CONSUMO EM kWh\t215", "pt", "a heading's words beside a unit"),
            ("АКТ И СЧЁТ", "АКТ И СЧЁТ от 12.05.2025", "ru", "a heading in another script"),
            ("RECLAMAÇÃO DE FATURA", "Assunto: RECLAMAÇÃO\nda fatura de julho", "pt", "a form's value printed in capitals"),
            ("FATURA VODAFONE JULHO", "Consulte em www.Fatura-Vodafone-Julho.pt", "pt", "a web address's letters"),
            ("MARIA EXEMPLO", "Para: Maria <Maria.Exemplo@example.com>", "pt", "an e-mail address's letters"),
            ("MARIA EXEMPLO", "MARIA EXEMPLO\nSkype: Maria_Exemplo", "pt", "a user's name"),
            ("FATURA ELETRONICA", "Siga-nos no Instagram: @Fatura-Eletronica", "pt", "a user's name an @ begins"),
            ("MARIA FATURAS", "Guardado em /srv/Maria/Faturas", "pt", "a path's letters"),
            ("MARIA FATURAS", "Guardado em /Maria-Faturas", "pt", "a path's letters at its start"),
            ("MARIA FATURAS", "Guardado em ~/Maria-Faturas", "pt", "a home path's letters"),
            ("MARIA EXEMPLO", "Pasta: C:/Maria-Exemplo", "pt", "a drive path's letters"),
            ("CONTRATO DE ARRENDAMENTO", "CONTRATO DE ARRENDAMENTO\nGuardado em Arquivo/2026/Contrato De Arrendamento", "pt",
             "a relative path's letters"),
            ("MARIA FATURAS", "Guardado em D:\\Arquivo\\Maria\\Faturas", "pt", "a Windows path's letters"),
            ("IHTARNAME KIRA SÖZLEŞMESI", "İhtarname kira sözleşmesi hakkındadır.", "tr", "a Turkish I the document writes dotted"),
            ("İHTARNAME KİRA SÖZLEŞMESİ", "İhtarname kira sözleşmesi hakkındadır.", "en", "a dotted capital another language's rules do not give"),
            ("ＦＡＴＵＲＡ ＤＥ ＬＵＺ", "Fatura de luz de julho", "pt", "capitals of another width"),
        ]
        try Self.goesBackOnce(unknown)
        var seen = Fixtures.content("card.jpg", text: "PORTUGAL\nTÍTULO DE RESIDÊNCIA\nAIMA, I.P.", date: nil)
        seen.visual = VisualSummary(imageKind: .idCard, description: "A Portuguese residence permit card (Título de Residência) issued by AIMA.",
                                    visibleTextSummary: "", organisations: [], dates: [])
        let described = try Fixtures.validator(try PipelineConfig.bundledDefaults().labels, grounds: Fixtures.grounds(seen))
            .validate(Fixtures.answer([.sender: [], .party: [], .date: []], title: "TÍTULO DE RESIDÊNCIA"), sentBack: Self.told("title"))
        #expect(described.title == "TÍTULO DE RESIDÊNCIA", "what the vision model wrote of it is no writing of the document's: \(described.notes)")

        #expect(AnswerValidator.inCapitals("СЧЁТ ЗА ЭЛЕКТРОЭНЕРГИЮ") && !AnswerValidator.inCapitals("IRS 2025")
                    && !AnswerValidator.inCapitals("電気料金のお知らせ") && !AnswerValidator.inCapitals("Payslip August")
                    && !AnswerValidator.inCapitals("NTT 請求書"),
                "capitals in any cased script go back; one abbreviation, alone or beside a script without case, does not")
    }

    @Test(arguments: [
        ("IMI AT", "NOTA DE COBRANÇA\nO IMI é cobrado pela AT em maio", "pt", "abbreviations among small letters"),
        ("IMI AT", "O imposto é cobrado pela AT em maio. IMI", "pt", "a word before a dot no number follows"),
        ("IMI AT", "O imposto foi cobrado pela AT em maio. IMI 2025", "pt", "a word before a dot, an abbreviation and its year"),
        ("IMI AT", "IMI liquidado. A 15 de maio pago à AT", "pt", "a word before a dot and a sentence begun with a day"),
        ("IMI AT", "Cobrado pela AT em maio\nIMI pago (2025)", "pt", "a word a bracket parts from a number"),
        // What is read as words, as a colon parts any label from its value and a dot or a space ends a sentence before
        // an abbreviation and its year ("Relatório: Q3 2025", "maio. IMI 2025"), though a number's name and its number
        // stand there too.
        ("INVOICE ACME", "ACME Ltd\nINVOICE No: ABC123", "en", "a number's name a colon parts from a number of as many letters"),
        ("INVOICE ACME", "ACME Ltd\nINVOICE No. FT 2026/1", "en", "a number's name a dot parts from its series' letters"),
        ("FATURA EDP", "EDP Comercial\nFATURA No FT 2026/1", "pt", "a number's name a space parts from its series' letters"),
    ])
    func aTitleOfWordsTheDocumentWritesInCapitalsBesideASentenceIsAsAsked(_ title: String, text: String, language: String, why: String) throws {
        let reading = try Self.validate([.sender: [], .party: []], title: title, text: text, language: language)
        #expect(reading.title == title && reading.notes.isEmpty, "\(why): written as abbreviations stand, as asked: \(reading.notes)")
    }

    /// An e-mail's subject and sender are its own writing, which a title in capitals is written as (`ReadingGrounds`).
    @Test(arguments: [
        (MetadataKey.emailSubject, "Fatura de eletricidade de julho", "FATURA DE ELETRICIDADE", "Fatura de eletricidade"),
        (MetadataKey.emailFrom, "Serviço de Faturas Eletrónicas <faturas@example.pt>", "SERVIÇO DE FATURAS", "Serviço de Faturas"),
    ])
    func aTitleIsWrittenAsAnEmailsSubjectOrSenderWritesIt(_ key: String, value: String, title: String, sentence: String) throws {
        var mail = Fixtures.content("aviso.eml", text: "Segue em anexo.")
        mail.metadata[key] = value
        let validator = try Fixtures.validator(try PipelineConfig.bundledDefaults().labels, grounds: Fixtures.grounds(mail))
        let reading = try validator.validate(Fixtures.answer([.sender: [], .party: []], title: title))
        #expect(reading.title == sentence, "the mail's own writing, not only its text: \(reading.notes)")
    }

    @Test func aHeadingBesideANumberSignAUnitOrANumbersNameIsNotWrittenAnew() throws {
        try Self.goesBackOnce([
            ("RECIBO EDP", "EDP Comercial\nRECIBO nº 12", "pt", "a heading beside a number sign"),
            ("CONSUMO EDP", "EDP Comercial\nCONSUMO kWh 215", "pt", "a heading beside a unit"),
            ("CONSUMO KWH", "CONSUMO kWh\t215", "pt", "a heading's word beside a unit, written as asked"),
            ("RECIBO Nº 12", "RECIBO nº 12", "pt", "a heading's word beside a number sign, written as asked"),
            ("FATURA EDP", "EDP Comercial\nFATURA 2026/1", "pt", "a heading beside a number"),
            ("INVOICE ACME", "ACME Ltd\nINVOICE No. 4711", "en", "a heading beside a number's name"),
            ("INVOICE NO. 4711", "INVOICE No. 4711", "en", "a heading beside a number's name, written as asked"),
            ("RECHNUNG DHL", "DHL Paket GmbH\nRECHNUNG Nr. 4711", "de", "a heading beside a number's name"),
            ("FACTURE EDF", "EDF Commerce\nFACTURE n° 2025-001", "fr", "a heading beside a number's name and a degree sign"),
            ("FACTURE EDF", "EDF Commerce\nFACTURE n° AB12", "fr", "a heading beside a number's name and a degree sign, its number of as many letters"),
            ("FAKTURA PGE", "PGE Obrót\nFAKTURA nr 123/2025", "pl", "a heading beside a number's name with no sign"),
            ("FAKTURA PGE", "PGE Obrót\nFAKTURA nr FV/2025/123", "pl", "a heading beside a number's name, its number begun with letters"),
            ("ΤΙΜΟΛΟΓΙΟ ΔΕΗ", "ΔΕΗ Ανανεώσιμες\nΤΙΜΟΛΟΓΙΟ Αρ. 123", "el", "a heading beside a number's name in Greek"),
            ("FATURA TTNET", "TTNET Anonim\nFATURA No: 123", "tr", "a heading beside a number's name and a colon"),
            ("FATURA TTNET", "TTNET Anonim\nFATURA No:1", "tr", "a heading beside a number's name and a colon with no space"),
            ("INVOICE ACME", "ACME Ltd\nINVOICE No. INV-2026-118", "en", "a heading beside a number's name, its number begun with letters"),
            ("INVOICE ACME", "ACME Ltd\nINVOICE No. ABC123", "en", "a heading beside a number's name, its number of as many letters"),
            ("FATURA EDP", "EDP Comercial\nFATURA Nº FT 2026/1", "pt", "a heading beside a number sign in capitals"),
            ("INVOICE ACME", "ACME Ltd\nINVOICE nr 1A", "en", "a heading beside a number's name, its number begun with a digit"),
            ("FAKTURA PGE", "PGE Obrót\nFAKTURA nr FV_2025_123", "pl", "a heading beside a number an address's form holds"),
            ("INVOICE NO. INV-2026-118", "INVOICE No. INV-2026-118", "en", "a heading beside a number begun with letters, written as asked"),
        ])
    }

    @Test func aReferenceThatSaysWhatItIsInAnotherLanguageGoesBack() throws {
        let sent = #expect(throws: GuessSentBack<ValidatedAnalysis>.self, "what a reference is, in the document's own words") {
            try Self.validate([.reference: ["Zählernummer 1ESY 1160 4478 21", "お客さま番号 03-3542-5545-25", "номер договора 1234",
                                            "invoice FT 2026/926804564"]])
        }
        #expect(sent?.problems == [
            "references: “Zählernummer 1ESY 1160 4478 21”, “お客さま番号 03-3542-5545-25”, “номер договора 1234” say what they are in "
                + "another language; write one or two English words for what each is, then its number as the document writes it",
        ])
        #expect(sent?.standing.labels.values(.reference) == ["Zählernummer 1ESY 1160 4478 21", "お客さま番号 03-3542-5545-25",
                                                              "номер договора 1234", "invoice FT 2026/926804564"],
                "words the document does not print as a field's name may be part of the number, and stand")
        let english = try Self.validate([.reference: ["invoice FT 2026/926804564", "customer account 764946860856", "contract C-2024-118",
                                                      "case 1234/24.5T8LSB", "2026/926804564"]])
        #expect(english.notes.isEmpty, "English words, words too short to tell, and a number alone stand: \(english.notes)")
    }

    @Test(arguments: [
        ("Plate ΙΚΤ 1234", "el"), ("Plate СА 1234 АВ", "bg"), ("Contract АБ 123456", "ru"), ("Licence plate 品川 300 あ 12-34", "ja"),
        ("ИНН 7784210225", "ru"), ("NIF 999999990", "pt"), ("Client 4711", "fr"), ("Reference 4711", "fr"), ("Code 9921", "fr"),
        ("Document 77", "fr"), ("Contract 123", "ro"), ("document number P01172476", "pt"),
    ])
    func aReferenceDescribedInEnglishStandsWhateverItsNumberIsWritten(_ reference: String, language: String) throws {
        let text = "Référence client\t4711\nCode d'accès\t9921\nClient\t4711\nDocument n°\t77\nContract\t123\nN.º DOCUMENTO / DOCUMENT NO."
        let reading = try Self.validate([.reference: [reference]], text: text, language: language)
        #expect(!reading.notes.contains { $0.hasPrefix("references") } && reading.labels.values(.reference) == [reference],
                "the letters of a number, in any script, and English words the document's language shares: \(reading.notes)")
    }

    @Test func aFieldsNameCopiedFromADocumentInAnotherLanguageIsLeftOutWhereItPrintsItBesideTheNumber() throws {
        let fatura = "Fatura de eletricidade\nFatura n.º\tFT EDPC2026/926804564\nN.º de conta cliente\t123456780\nNIF\t999999990\n"
            + "Série\tA 123\nCódigo do contrato 9 87"
        let copied = ["Fatura n.º FT EDPC2026/926804564", "N.º de conta cliente 123456780", "NIF 999999990", "Série A 123",
                      "Código do contrato 9 87", "customer account 123456780"]
        let sent = #expect(throws: GuessSentBack<ValidatedAnalysis>.self, "a field's name copied from a document in Portuguese") {
            try Self.validate([.reference: copied], text: fatura, language: "pt")
        }
        #expect(sent?.problems == ["references: “Código do contrato 9 87” say what they are in another language; write one or two English "
                                       + "words for what each is, then its number as the document writes it"],
                "only words the document runs into the number go back; an abbreviation and English words are no copy")
        let written = ["FT EDPC2026/926804564", "123456780", "NIF 999999990", "A 123", "Código do contrato 9 87", "customer account 123456780"]
        #expect(sent?.standing.labels.values(.reference) == written,
                "a field's name printed beside its number is left out at once, a series' letter kept: \(sent?.standing.notes ?? [])")
        #expect(sent?.standing.notes.contains("references: “Série A 123” says what it is in the document's words, its field's name, written "
                                                  + "as the document tells: “A 123”") == true, "and noted")
        let again = try Self.validate([.reference: copied], text: fatura, language: "pt", sentBack: Self.told("references"))
        #expect(again.labels.values(.reference) == written, "given again, what the document does not set apart stands as given")
        let above = try Self.validate([.reference: ["お客さま番号 03-3542-5545-25"]], text: "東京電力\nお客さま番号\n03-3542-5545-25", language: "ja")
        #expect(above.labels.values(.reference) == ["03-3542-5545-25"], "a field's name printed above its number is left out too: \(above.notes)")
        let ending = try Self.validate([.reference: ["Fatura n.º FT EDPC2026/926804564"]], text: "Tipo de documento Fatura n.º\tFT EDPC2026/926804564",
                                       language: "pt")
        #expect(ending.labels.values(.reference) == ["FT EDPC2026/926804564"], "and one that ends a cell: \(ending.notes)")
        let contract = "Contrato 12345 celebrado em Lisboa\nAs condições constam do contrato"
        let ran = try Self.validate([.reference: ["Contrato 12345"]], text: contract, language: "pt", sentBack: Self.told("references"))
        #expect(ran.labels.values(.reference) == ["Contrato 12345"],
                "a word the document runs into the number, and writes elsewhere at a cell's end, is no field's name: \(ran.notes)")
        let invoice = "ACME Ltd\nInvoice No.\tINV-2026-118\nBill to\tMaria Exemplo\nIssued 05/07/2026"
        let own = try Self.validate([.sender: ["ACME Ltd"], .reference: ["Invoice No. INV-2026-118"]], text: invoice, language: "en")
        #expect(own.labels.values(.reference) == ["Invoice No. INV-2026-118"] && own.notes.isEmpty,
                "an English document's own words for what a reference is stand: \(own.notes)")
    }

    /// A document is laid out in passes linear in its size, however its text is written: many lines with addresses, and
    /// a run of a million characters with no space in it, and a title is checked against it in one pass over the title's
    /// words, however many (AGENTS.md §4.5; the fifth and sixth reviews of the fix of READ-6, which found the system's
    /// link detector far slower than linear on a large document, and a title's words each looked for in all of it).
    @Test(.timeLimit(.minutes(1))) func aLargeDocumentIsLaidOutInPassesLinearInItsSize() throws {
        let lines = String(repeating: "Fatura n.º FT 2026/1 de Maria Exemplo em www.edp.pt para faturas@edp.pt\tvalor 57,43 €\n", count: 10_000)
        let grounds = try Fixtures.grounds(lines + String(repeating: "a.b", count: 330_000) + " " + String(repeating: "ab-1", count: 250_000)
                                           + "\nO IMI é cobrado pela AT")
        #expect(grounds.layout.asSentence("MARIA EXEMPLO EM") == "Maria Exemplo em", "and what it writes is read from it")
        #expect(grounds.layout.writesInCapitals(String(repeating: "IMI ", count: 100_000)),
                "a title's every word, written in capitals beside a sentence at the document's end, is as asked")
        let repeated = try Fixtures.validator(try PipelineConfig.bundledDefaults().labels,
                                              grounds: Fixtures.grounds(String(repeating: "A a ", count: 50_000)))
        let long = Array(repeating: "A", count: 200).joined(separator: " ")
        let longest = Array(repeating: "A", count: 60).joined(separator: " ")
        #expect(repeated.sentence(long) == nil && repeated.sentence("A A") == "A a" && repeated.sentence(longest) != nil,
                "a title longer than a file name holds is never looked for; one it holds is, in one pass over the words for each")
    }
}
