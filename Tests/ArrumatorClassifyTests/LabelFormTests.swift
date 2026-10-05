@testable import ArrumatorClassify
import ArrumatorCore
import ArrumatorTesting
import Foundation
import NaturalLanguage
import Testing

/// What the model answers is kept only in the form each kind of label has (docs/how-it-works.md#labels), only when the
/// document itself writes it, and the file is named by the labels kept: the QA run of 4 October 2026 found labels that
/// copied the prompt's wording ("account and its number: 123456780"), numbers given as people, two labels in one, a
/// sender the document never names, and names with a period where the date goes or a separator left dangling.
@Suite struct LabelFormTests {
    /// The reading of `text` an answer of `overrides` and `title` gives; without a title, one of the text's own words, its
    /// first line, as the title is checked against them too (`ReadingGrounds.unwritten`).
    static func validate(_ overrides: [LabelKind: [String]], title: String? = nil, text: String = Fixtures.edpText,
                         preferred: [LabelPreference] = []) throws -> ValidatedAnalysis {
        var labels = try PipelineConfig.bundledDefaults().labels
        labels.maxPerKind = 6
        let heading = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return try Fixtures.validator(labels, grounds: Fixtures.grounds(text, preferred: preferred))
            .validate(Fixtures.answer(overrides, title: title ?? heading))
    }

    // MARK: READ-1

    @Test func anObjectOrAReferenceIsWhatItIsAndWhatIdentifiesItNeverAFieldAndItsValue() throws {
        let v = try Self.validate([.object: ["account: 123456780", "residence permit : S61271191", "meeting room 12:30"],
                                   .reference: ["company number: 01234567", "appointment:  AG-2026-5114424", "order AB:12"]])
        #expect(v.labels.values(.object) == ["account 123456780", "residence permit S61271191", "meeting room 12:30"],
                "a field's name and its value are what it is and what identifies it, as the kind writes them; a colon inside a value stays")
        #expect(v.labels.values(.reference) == ["company number 01234567", "appointment AG-2026-5114424", "order AB:12"],
                "and so are a reference's")
    }

    @Test func anAmountIsANumberAndItsCurrencyNeverAPercentage() throws {
        let v = try Self.validate([.amount: ["5.00% GBP", "1 234,56 €", "EUR 1.234.567,89", "12,50€", "-3.10 usd", "100 $", "1.5 ABC"]])
        #expect(v.labels.values(.amount) == ["1234.56 EUR", "1234567.89 EUR", "12.50 EUR", "-3.10 USD"],
                "a number with a dot for decimals and no grouping, and the ISO 4217 code of its currency, from a symbol only it has")
        for dropped in ["5.00% GBP", "100 $", "1.5 ABC"] {
            #expect(v.notes.contains("amounts: “\(dropped)” is no amount, dropped"),
                    "a percentage, a symbol several currencies share and a code no currency has are no amount: \(v.notes)")
        }
    }

    static func systemPrompt() throws -> String {
        try PromptLibrary.bundled().render("labels-system", ["max_per_kind": "3", "max_name_chars": "120"])
    }

    /// The values the prompt's line for the field `key` quotes.
    static func examples(of key: String) throws -> [String] {
        let line = try #require(try systemPrompt().components(separatedBy: "\n").first { $0.hasPrefix("- \(key):") }, "the prompt has a line for \(key)")
        return line.matches(of: /"([^"]+)"/).map { String($0.output.1) }
    }

    /// The kinds whose form is not a name the document writes, which the prompt shows by examples, never by a pattern.
    static let shownByExample: [LabelKind] = [.topic, .object, .reference, .date, .period, .deadline, .amount, .jurisdiction, .language]

    @Test func thePromptsExamplesOfAKindAreLabelsOfThatKindAsTheyAreKept() throws {
        for kind in LabelKind.modelKinds {
            let examples = try Self.examples(of: ClassificationSchema.labelsKey(kind))
            if Self.shownByExample.contains(kind) {
                #expect(!examples.isEmpty, "\(kind.rawValue): the prompt shows values, not a description the model copies as a template")
            }
            for example in examples {
                #expect(DocumentLabel.normalized(example, kind: kind)?.value == example,
                        "\(kind.rawValue): “\(example)” is written as the label it is an example of")
            }
        }
        for amount in try Self.examples(of: ClassificationSchema.labelsKey(.amount)) {
            let code = try #require(amount.split(separator: " ").last.map(String.init))
            #expect(Locale.commonISOCurrencyCodes.contains(code),
                    "“\(amount)” is in a currency a country uses, not a placeholder code that only stands for one: \(code)")
        }
    }

    @Test func theTitlesExamplesAreInSeveralLanguagesAndTheTitleInTheDocuments() throws {
        let examples = try Self.examples(of: ClassificationSchema.titleKey)
        let languages = Set(examples.compactMap { example -> NLLanguage? in
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(example)
            return recognizer.dominantLanguage
        })
        #expect(examples.isEmpty || languages.count > 1,
                "a title copies the language of a single example, as English documents were titled in Portuguese: \(examples)")
        #expect(try Self.systemPrompt().contains("in the language its own text is written in, the first under languages, even when"),
                "the title is in the document's own language whatever else the prompt is in")
    }

    @Test func theSenderOfAContractIsThePartyThatIssuesIt() throws {
        let system = try Self.systemPrompt()
        #expect(system.contains("A contract, a lease or an agreement is issued by the party that offers it, such as the landlord"),
                "a lease names its landlord, its sender, which a rule against invented senders must not leave out")
        #expect(system.contains("A short note that names no one who wrote or issued it has no sender"),
                "while a note that names no issuer still has none")
    }

    // MARK: READ-2

    @Test func aNameAThingATopicOrAPlaceWithoutALetterIsNone() throws {
        let v = try Self.validate([.sender: ["503504564", "EDP Comercial"], .party: ["999999990", "Maria Exemplo"], .topic: ["2024", "electricity"],
                                   .object: ["123456780"], .jurisdiction: ["351", "Portugal"]])
        #expect(v.labels.values(.sender) == ["EDP Comercial"] && v.labels.values(.party) == ["Maria Exemplo"],
                "a tax number is no person or organisation")
        #expect(v.labels.values(.topic) == ["electricity"] && v.labels.values(.object).isEmpty && v.labels.values(.jurisdiction) == ["Portugal"],
                "a topic is words, an object says what it is, a jurisdiction is a name")
        #expect(v.notes.contains("parties: “999999990” is no party, dropped"), "the trace says which was dropped: \(v.notes)")
        #expect(DocumentLabel.normalized("999999990", kind: .party) == nil && DocumentLabel.normalized("Maria", kind: .party) != nil,
                "a label the user gives is held to the same form")
    }

    // MARK: READ-3

    @Test func twoLabelsInOneEntryAreTwo() throws {
        let v = try Self.validate([.topic: ["banking; account statement", #""utilities""#], .sender: ["EDP Comercial;"]])
        #expect(v.labels.values(.topic) == ["banking", "account statement", "utilities"],
                "an entry holding the list separator is the labels it separates, and a label copied in its quotes is the label")
        #expect(v.labels.values(.sender) == ["EDP Comercial"], "a separator with nothing after it adds nothing")
    }

    // MARK: VOC-1

    @Test func everyPromptListsALabelHoldingASeparatorAsTheOneLabelItIs() async throws {
        let config = try PipelineConfig.bundledDefaults()
        let topics = ["banking", "banking; account statement", "rent, deposit", #"the "quoted" one"#]
        let listed = #"- topics: "banking", "banking; account statement", "rent, deposit", "the \"quoted\" one""#
        let prompts = PromptBuilder(library: try PromptLibrary.bundled(), config: config.analysis, labels: config.labels, naming: config.naming)
        let reading = try prompts.archiveBlock(LabelGuidance(used: [.topic: topics]))
        #expect(reading.contains(listed + "\n"), "the labels a document is read with: \(reading)")

        let w = try await SearchInterpreterTests().world { _ in try SearchInterpreterTests.answer() }
        defer { w.env.cleanup() }
        let usage = topics.map { LabelUsage(label: DocumentLabel(kind: .topic, value: $0), documents: 1) }
        let searching = try w.interpreter.archiveBlock([.topic: usage], limits: [.topic: topics.count])
        #expect(searching.contains(listed + "\n"), "the labels a request is read with: \(searching)")

        let document = ContextDocument(id: 1, name: "Extrato.pdf", date: nil, labels: topics.map { DocumentLabel(kind: .topic, value: $0) }, text: nil)
        #expect(TaskAnswerer.about(document) == listed.dropFirst(2).replacingOccurrences(of: "topics:", with: "topic:"),
                "the labels a question is answered with")
    }

    // MARK: READ-4

    static let note = "QA notificação única: lembrete para pagar a renda de outubro, 950 euros, até dia 8."

    @Test func aSenderOrAPartyTheDocumentDoesNotWriteIsNone() throws {
        let v = try Self.validate([.sender: ["Portal das Finanças"], .party: ["Maria Exemplo"], .date: []], title: "Lembrete renda outubro", text: Self.note)
        #expect(v.labels.values(.sender).isEmpty && v.labels.values(.party).isEmpty,
                "a name the note never writes, such as the archive's most used sender, is none")
        #expect(v.notes.contains("senders: “Portal das Finanças” is not written in the document, dropped"), "and the trace says so: \(v.notes)")
        #expect(try Self.name(v) == "Lembrete renda outubro", "and the name is not made of it")

        let written = try Self.validate([.sender: ["Сбербанк", "Finanças"], .party: ["MARIA EXEMPLO"]],
                                        text: "Выписка ПАО Сбербанка для Maria Exemplo. Autoridade Tributária",
                                        preferred: [LabelPreference(from: DocumentLabel(kind: .sender, value: "Autoridade Tributária"), to: "Finanças")])
        #expect(written.labels.values(.sender) == ["Сбербанк", "Finanças"] && written.labels.values(.party) == ["MARIA EXEMPLO"],
                "a name the document writes, declined, cased otherwise, or as the owner wants one it writes written, is kept")
    }

    /// A name and a text that writes it: in full width, with the Turkish I, spaced out letter by letter, with a soft
    /// hyphen, broken at the end of a line, as an abbreviation in capitals; and, as controls the fold kept, in Cyrillic
    /// and with a ligature.
    static let writtenOtherwise: [(name: String, text: String)] = [
        ("Социальный фонд России", "СНИЛС\nСФР\nСтраховой номер индивидуального лицевого счёта 112-233-445 95"),
        ("Autoridade Tributária", "AT - Nota de cobrança IRS 2025"),
        ("HM Passport Office", "UNITED KINGDOM OF GREAT BRITAIN AND NORTHERN IRELAND\nAuthority HMPO\nDate of issue 01 MAR 2022"),
        ("NTTドコモ", "ご請求書 株式会社ＮＴＴドコモ 2026年7月分"),
        ("İş Bankası", "TÜRKİYE IŞ BANKASI A.Ş. HESAP ÖZETİ"),
        ("IŞ BANKASI", "Türkiye İş Bankası hesap özeti"),
        ("EDP Comercial", "E D P  C O M E R C I A L\nFatura n.º FT 2026/926804564"),
        ("EDP Comercial", "Fatura EDP Comer\u{00AD}cial, S.A."),
        ("EDP Comercial", "Fornecedor: EDP Comer-\ncial, S.A."),
        ("Сбербанк", "Выписка ПАО Сбербанка по счёту"),
        ("Office Depot", "Oﬃce Depot receipt"),
    ]

    @Test(arguments: writtenOtherwise)
    func aNameTheDocumentWritesIsGroundedHoweverItIsWidenedCasedSpacedOrBroken(_ written: (name: String, text: String)) throws {
        let v = try Self.validate([.sender: [written.name], .party: []], text: written.text)
        #expect(v.labels.values(.sender) == [written.name], "“\(written.name)” is written in “\(written.text)”: \(v.notes)")
    }

    @Test func aNameIsGroundedByItsInitialsOnlyWhereTheDocumentWritesThemInCapitals() throws {
        let v = try Self.validate([.sender: ["Autoridade Tributária", "Social Fund"], .party: []], text: "Meet me at the office, sf")
        #expect(v.labels.values(.sender).isEmpty, "“at” and “sf” in lower case are words, not the abbreviations of names: \(v.notes)")
        #expect(ReadingGrounds.initials(of: "Banco de Portugal") == ["bdp", "bp"] && ReadingGrounds.initials(of: "EDP").isEmpty,
                "a name of several words is abbreviated by all its words and by those it capitalises; one of one word is not")
    }

    /// A name and a text that does not write it, though the text's letters, run together across its words, or one of
    /// its words, or a legal form in capitals, would have grounded it (second review of 2026-10-04, finding 4).
    static let notWritten: [(name: String, text: String)] = [
        ("EDP", "Estimated payment due 25 July"),
        ("Sónia Almeida", "Fatura EDP Comercial SA"),
        ("EDP Comercial", "Extrato Banco Comercial Português"),
    ]

    @Test(arguments: notWritten)
    func aNameTheDocumentDoesNotWriteAsWordsIsNotGrounded(_ written: (name: String, text: String)) throws {
        let v = try Self.validate([.sender: [written.name], .party: []], text: written.text)
        #expect(v.labels.values(.sender).isEmpty, "“\(written.name)” is not written in “\(written.text)”")
    }

    /// Initials of fewer letters than labels.groundingLetters, as so many words and legal forms are, ground a name of as
    /// many words only where they begin a line, as a heading or letterhead writes them; longer ones wherever they stand.
    @Test func shortInitialsGroundANameOnlyWhereTheyBeginALine() throws {
        let heading = try Self.validate([.sender: ["Sónia Almeida"], .party: []], text: "SA\nRecibo de renda")
        #expect(heading.labels.values(.sender) == ["Sónia Almeida"], "two capitals that begin a line are the name's initials: \(heading.notes)")
        let suffix = try Self.validate([.sender: ["Sónia Almeida"], .party: []], text: "Recibo EDP Comercial SA")
        #expect(suffix.labels.values(.sender).isEmpty, "after a name they are its legal form: \(suffix.notes)")
        let three = try Self.validate([.sender: ["Banco de Portugal"], .party: []], text: "Carta do BdP\nEnviada pelo BP")
        #expect(three.labels.values(.sender).isEmpty, "mixed case, or two letters for a name of three words, ground nothing: \(three.notes)")
        let whole = try Self.validate([.sender: ["Banco de Portugal"], .party: []], text: "Carta do BDP sobre a conta")
        #expect(whole.labels.values(.sender) == ["Banco de Portugal"], "three capitals ground it wherever they stand: \(whole.notes)")
    }

    // MARK: Titles

    static let hetzner = """
        Hetzner Online GmbH
        Invoice 042/2026
        Cloud services September 2026: CX22 server, 4.51 EUR
        """

    /// The title is made of the document's own words, as the prompt asks: one fewer than analysis.titleGroundedShare of
    /// whose words the document writes goes back to the model naming them, while numbers and short words, which say
    /// nothing of its language, are not counted (QA 2026-10-04, titles in Portuguese of English documents).
    @Test func aTitleOfWordsTheDocumentDoesNotWriteGoesBackNamingThem() throws {
        let sent = #expect(throws: GuessSentBack<ValidatedAnalysis>.self, "a Portuguese title of an English invoice goes back") {
            try Self.validate([.sender: [], .party: []], title: "Fatura serviços cloud", text: Self.hetzner)
        }
        #expect(sent?.problems == [
            "title: the title's words “Fatura”, “serviços” are not in the document; make the title of the document's own words, in its own language",
        ])
        let own = try Self.validate([.sender: [], .party: []], title: "Invoice cloud services", text: Self.hetzner)
        #expect(own.title == "Invoice cloud services" && own.notes.isEmpty, "a title of its words stands")
        let grounds = try Fixtures.grounds(Self.hetzner)
        #expect(grounds.unwritten("Invoice 2026 nº 42 de IVA", share: 0.5) == nil,
                "numbers and words shorter than labels.groundingLetters are not counted: one word of two is written")
        #expect(grounds.unwritten("Fatura 2026 nº 42", share: 0.5) == ["Fatura"], "the one word counted is not written")
        let blank = try Fixtures.grounds("")
        #expect(grounds.unwritten("2026 nº 42", share: 0.5) == nil && blank.unwritten("Fatura", share: 0.5) == nil,
                "a title with no word to count, or a document with no words to tell by, is not sent back")
    }

    @Test func aTitleSentBackOnceStandsAsTheModelGivesItAgain() async throws {
        for second in ["Invoice cloud services", "Fatura serviços nuvem cloud"] {
            let h = try await ClassifyHarness.make { request in
                try Fixtures.answer([.sender: ["Hetzner Online GmbH"], .party: []],
                                    title: request.messages.count > 2 ? second : "Fatura serviços cloud")
            }
            defer { h.env.cleanup() }
            let outcome = try await h.analyse(Fixtures.content("invoice.pdf", text: Self.hetzner, language: "en"))
            #expect(outcome.title == second && outcome.analysis.problems.isEmpty,
                    "the title given after being told stands, whatever its words: the document is not failed for it")
            #expect(await h.mock.chatRequests.last?.messages.last?.content.contains("“Fatura”, “serviços” are not in the document") == true,
                    "the repair names the words the document does not write")
            let step = try #require(await h.steps(.analyse).first)
            #expect(try step.exchange().count == 2 && step.status == .warn, "the trace keeps both calls")
            let kept = step.output?.contains("are not in the document, kept as the model gives it again") == true
            #expect(kept == (second != "Invoice cloud services"), "and says when a title still not of its words was kept")
        }
    }

    /// An object is a thing the document identifies by a number, a plate or an address: one with no word of
    /// labels.objectIdentifierDigits digits, as a fact about a person or a product bought, whose quantity ("1L", "x6")
    /// identifies nothing, goes back to the model named (QA 2026-10-04, READ-5), and the answer as it is would stand.
    @Test func anObjectNothingIdentifiesGoesBackNamingIt() throws {
        let sent = #expect(throws: GuessSentBack<ValidatedAnalysis>.self, "a job title and groceries go back") {
            try Self.validate([.object: ["job title Senior Software Engineer", "bread integral milk 1L x6", "car AA-12-BB"]])
        }
        #expect(sent?.problems == [
            "objects: “job title Senior Software Engineer”, “bread integral milk 1L x6” hold no number; keep each only when a number, a "
                + "plate, an address or a name the document writes identifies one thing, never a fact about a person nor a kind of thing alone",
        ])
        #expect(sent?.standing.labels.values(.object).count == 3
                    && sent?.standing.notes.contains { $0.hasSuffix(AnswerValidator.keptUnrepaired) } == true,
                "with no repair left, the answer stands as it is, and its notes say so")
        let identified = try Self.validate([.object: ["car AA-12-BB", "apartment Rua das Flores 12, Porto", "savings account 0012345678",
                                                      "home Calle del Ejemplo 7"]])
        #expect(identified.labels.values(.object).count == 4 && identified.notes.isEmpty,
                "a plate, an address, a number, and a house number of one digit after its street's name identify")
        var labels = try PipelineConfig.bundledDefaults().labels
        labels.maxValueChars = 24
        let cut = try Fixtures.validator(labels, grounds: Fixtures.grounds(Fixtures.edpText))
            .validate(Fixtures.answer([.object: ["electricity supply point PT0002000012345678"]]))
        #expect(cut.labels.values(.object) == ["electricity supply point"] && cut.notes.isEmpty,
                "an object is told by its whole value, before it is cut to labels.maxValueChars")
    }

    /// A reading's date is one the document writes (QA 2026-10-04, READ-4: a note given 2023-10-08, which it writes no
    /// date at all): a date given to a document in which the extractor finds none, nor the vision model saw one, goes back
    /// named; a document with dates keeps the one the model reads, and one with nothing to tell by is not checked.
    @Test func aDateTheDocumentDoesNotWriteGoesBackNamingIt() throws {
        let labels = try PipelineConfig.bundledDefaults().labels
        let note = try Fixtures.validator(labels, grounds: Fixtures.grounds(Fixtures.content("nota.txt", text: Self.note, date: nil)))
        let sent = #expect(throws: GuessSentBack<ValidatedAnalysis>.self, "a date the note never writes goes back") {
            try note.validate(Fixtures.answer([.date: ["2023-10-08"]], title: "Lembrete renda"))
        }
        #expect(sent?.problems == [
            "dates: “2023-10-08”, while the document writes no date, nor that year; give a date only as the document writes it, with its "
                + "year, or [] when it writes none",
        ])
        #expect(try note.validate(Fixtures.answer([.sender: [], .party: [], .date: []], title: "Lembrete renda")).notes.isEmpty, "no date is the note's answer")
        let bill = try Fixtures.validator(labels, grounds: Fixtures.grounds(Fixtures.content("edp.pdf", text: Fixtures.edpText)))
        #expect(try bill.validate(Fixtures.answer()).labels.values(.date) == ["2026-07-05"], "the date the bill writes stands")
        #expect(try bill.validate(Fixtures.answer([.date: ["2026-05-07"]])).labels.values(.date) == ["2026-05-07"],
                "and so does another the model reads in it, as a date written month first, or in another calendar, may be read")
        var seen = Fixtures.content("talao.jpg", text: "", date: nil)
        seen.visual = VisualSummary(imageKind: .photo, description: "A till receipt", visibleTextSummary: "", organisations: [],
                                    dates: ["05/07/2026"])
        let picture = try Fixtures.validator(labels, grounds: Fixtures.grounds(seen))
        #expect(try picture.validate(Fixtures.answer([.sender: [], .party: []], title: "Till receipt")).notes.isEmpty,
                "a date the vision model saw in a picture is the document's")
        let card = try Fixtures.validator(labels, grounds: Fixtures.grounds(Fixtures.content("card.jpg", text: "EMITIDO EM\n01 FEV 25", date: nil)))
        #expect(try card.validate(Fixtures.answer([.sender: [], .party: [], .date: ["2025-02-01"]], title: "Emitido")).notes.isEmpty,
                "a date the extractor cannot read stands when the document writes its year, in full or in two digits")
        let blank = try Fixtures.validator(labels, grounds: Fixtures.grounds(Fixtures.content("scan.png", text: "", date: nil)))
        #expect(try blank.validate(Fixtures.answer([.sender: [], .party: []], title: "Scan")).notes.isEmpty,
                "a document nothing was read of has no dates to tell by, and is not checked")
    }

    /// A reading that names analysis.partiesWithoutSender parties and no sender goes back once, asking who issued the
    /// document (evaluation of prompt 10: leases and contracts naming both their sides as parties); one party alone, as a
    /// note addressed to someone, is not asked about.
    @Test func partiesWithoutASenderGoBackAskingWhoIssuedIt() throws {
        let lease = "Contrato de arrendamento\nSenhorio: João Exemplo\nArrendatária: Maria Exemplo\nRua Exemplo 12, Lisboa"
        let sent = #expect(throws: GuessSentBack<ValidatedAnalysis>.self, "both sides as parties, no sender") {
            try Self.validate([.sender: [], .party: ["João Exemplo", "Maria Exemplo"]], title: "Contrato de arrendamento", text: lease)
        }
        #expect(sent?.problems.first?.hasPrefix("senders: none, while the parties name “João Exemplo”, “Maria Exemplo”;") == true)
        let issued = try Self.validate([.sender: ["João Exemplo"], .party: ["Maria Exemplo"]], title: "Contrato de arrendamento", text: lease)
        #expect(issued.notes.isEmpty, "the landlord as sender and the tenant as party stand")
        let note = try Self.validate([.sender: [], .party: ["Maria Exemplo"]], title: "Contrato de arrendamento", text: lease)
        #expect(note.notes.isEmpty, "one party alone is not asked about")
    }

    /// A guess sent back when no repair is left, as after an answer that left a list out, stands: the document is never
    /// failed for what the model was not told (AGENTS.md §4.5).
    @Test func aGuessSentBackWithNoRepairLeftStands() async throws {
        try await standsWithNoRepairLeft(after: Fixtures.answer(omitting: .jurisdiction), then: Fixtures.answer([.object: ["job title Senior Software Engineer"]]),
                                         "a guess in the repair of a list left out")
        try await standsWithNoRepairLeft(after: Fixtures.answer([.object: ["job title Senior Software Engineer"]]), then: "not JSON",
                                         "a repair of a guess that comes to nothing")
        let guessing = try Fixtures.answer([.object: ["job title Senior Software Engineer"]])
        try await standsWithNoRepairLeft(after: MockOllama.cutOff(after: guessing), then: guessing,
                                         "a guess the model was never told of, as the answer that held it first was cut off")
    }

    private func standsWithNoRepairLeft(after first: String, then second: String, _ comment: Comment) async throws {
        let h = try await ClassifyHarness.make { request in request.messages.count > 2 ? second : first }
        defer { h.env.cleanup() }
        let outcome = try await h.analyse(Fixtures.content("edp.pdf", text: Fixtures.edpText))
        #expect(outcome.analysis.problems.isEmpty && outcome.labels?.values(.object) == ["job title Senior Software Engineer"],
                "\(comment): the answer with the guess stands, though it holds an object nothing identifies")
        let step = try #require(await h.steps(.analyse).first)
        #expect(try step.exchange().count == 2 && step.output?.contains(AnswerValidator.keptUnrepaired) == true
                    && step.output?.contains(AnswerValidator.keptGivenAgain) == false,
                "\(comment): the trace keeps both calls and says what was kept without being sent back, never as given again")
    }

    @Test func aNameAnyMergeOfTheOwnersWritesIsGroundedNotOnlyOneThePromptShows() throws {
        let config = try PipelineConfig.bundledDefaults()
        let shown = config.labels.vocabulary.promptPreferred
        let oldest = LabelPreference(from: DocumentLabel(kind: .sender, value: "Autoridade Tributária"), to: "Finanças")
        let newer = (1...shown).map { LabelPreference(from: DocumentLabel(kind: .topic, value: "topic \($0)"), to: "subject \($0)") }
        let guidance = LabelGuidance(preferred: newer + [oldest])
        let grounds = try Fixtures.grounds(Fixtures.content("nota.pdf", text: "Autoridade Tributária e Aduaneira"), guidance: guidance)
        #expect(grounds.holds("Finanças"), "a merge older than the newest labels.vocabulary.promptPreferred still writes the name the document writes")
        let prompts = PromptBuilder(library: try PromptLibrary.bundled(), config: config.analysis, labels: config.labels, naming: config.naming)
        let block = try prompts.archiveBlock(guidance)
        #expect(block.contains(#""topic \#(shown)""#) && !block.contains("Autoridade Tributária"),
                "while the prompt shows only the newest labels.vocabulary.promptPreferred of them: \(block)")
    }

    @Test func aLabelOfAKindTheModelGivesNeverHoldsTheSeparatorOfItsAnswer() throws {
        for kind in LabelKind.modelKinds where kind != .type && kind != .language {
            #expect(DocumentLabel.normalized("EDP; Comercial", kind: kind) == nil,
                    "\(kind.rawValue): a label holding “;” would be two in an answer, so none holds it")
        }
        #expect(DocumentLabel.normalized("Taxes; 2024", kind: .tag)?.value == "Taxes; 2024", "a tag, the user's own, is kept as written")
    }

    @Test func aDocumentIsGroundedInItsTextItsMailAndWhatWasSeenInIt() async throws {
        let h = try await ClassifyHarness.make { _ in try Fixtures.answer([.sender: ["Portal das Finanças", "EDP Comercial"], .party: ["Maria Exemplo"]]) }
        defer { h.env.cleanup() }
        var content = Fixtures.content("lembrete.eml", text: Self.note)
        content.metadata[MetadataKey.emailFrom] = "EDP Comercial <faturas@edp.pt>"
        content.metadata[MetadataKey.emailSubject] = "Lembrete para Maria Exemplo"
        let outcome = try await h.analyse(content, guidance: LabelGuidance(used: [.sender: ["Portal das Finanças"]]))
        #expect(outcome.labels?.values(.sender) == ["EDP Comercial"] && outcome.labels?.values(.party) == ["Maria Exemplo"],
                "the e-mail's sender and subject are the document's words; the archive's labels are not: \(outcome.labels ?? [])")
    }

    @Test func aNameOnlyThePictureShowsIsGroundedInWhatWasSeenInIt() throws {
        var content = Fixtures.content("talao.jpg", text: "")
        content.visual = VisualSummary(imageKind: .photo, description: "A till receipt from a Pingo Doce supermarket", visibleTextSummary: "",
                                       organisations: ["Continente"], dates: [])
        var labels = try PipelineConfig.bundledDefaults().labels
        labels.maxPerKind = 6
        let v = try Fixtures.validator(labels, grounds: Fixtures.grounds(content))
            .validate(Fixtures.answer([.sender: ["Pingo Doce", "Continente", "Lidl"], .party: []], title: "Till receipt supermarket"))
        #expect(v.labels.values(.sender) == ["Pingo Doce", "Continente"],
                "a name the vision model saw, in its description or among the organisations, is the document's; one it did not is not: \(v.notes)")
    }

    @Test func thePromptForbidsLabelsTheDocumentDoesNotState() throws {
        let system = try Self.systemPrompt()
        #expect(system.contains("never take a sender, a party, a date or an amount from THIS ARCHIVE"),
                "the archive's labels say how to write a label, never that the document has it")
        #expect(system.contains("a day and a month without a year has no date: never complete one"), "a year is never made up")
        #expect(system.contains("even a year of two digits as passports and cards write it"),
                "while a passport's 01 MAR 22 has its year, and its date of issue is no date to leave out")
    }

    // MARK: NAM-1, NAM-2, NAM-3

    /// The name a reading validated as `v` is given when the user's rules change none of its labels
    /// (`PipelineServices.read` makes it of the labels they keep).
    static func name(_ v: ValidatedAnalysis) throws -> String? {
        let config = try PipelineConfig.bundledDefaults()
        return try FilenameBuilder(config: config.naming, reserved: SkipRules(watcher: config.watcher))
            .made(date: v.labels.values(.date).first, sender: v.labels.values(.sender).first, title: #require(v.title))
    }

    @Test func theFileIsNamedByTheDateTheSenderAndTheTitleKept() throws {
        // Each document headed by its title, so the title is of its own words.
        func validate(_ overrides: [LabelKind: [String]], titled title: String) throws -> ValidatedAnalysis {
            try Self.validate(overrides, title: title, text: title)
        }
        let lease = try validate([.sender: [], .date: ["2025-08-20"]], titled: "Contrat de location - Claire Martin")
        #expect(try Self.name(lease) == "2025-08-20 Contrat de location - Claire Martin", "no sender leaves no separator after the date")
        let note = try validate([.sender: [], .date: [], .topic: ["home renovation"]], titled: "Segunda nota de teste sobre a caldeira")
        #expect(try Self.name(note) == "Segunda nota de teste sobre a caldeira", "no sender and no date leave the title alone, not a topic in their place")
        let budget = try validate([.sender: [], .date: [], .period: ["2026-01/2026-12"]], titled: "Household budget 2026 - Monthly expenses")
        #expect(try Self.name(budget) == "Household budget 2026 - Monthly expenses", "a period is never where the date goes")
        let dated = try validate([.sender: [], .date: ["2026-01-05"], .period: ["2026-01/2026-12"]], titled: "Household budget 2026")
        #expect(try Self.name(dated) == "2026-01-05 Household budget 2026", "the date goes there, the day the document was issued")
        let whole = try Self.validate([:], title: "2026-07-05 EDP Comercial - Fatura eletricidade julho")
        #expect(try Self.name(whole) == "2026-07-05 EDP Comercial - Fatura eletricidade julho", "a title written as a whole name repeats nothing")
        let invented = try Self.validate([.sender: ["Portal das Finanças"]], title: "Lembrete renda outubro", text: Self.note)
        #expect(try Self.name(invented) == "2026-07-05 Lembrete renda outubro", "a sender the document does not write names nothing")
        #expect(try Self.validate([:], title: " \n ").title == nil, "a blank title is none")
    }
}
