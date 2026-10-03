import ArrumatorCore
import Foundation
import Testing

@Suite("Stable keys")
struct StableKeysTests {
    /// What the labels of the bundled configuration find, and the keys the patterns of 429517b found in each variant,
    /// made once for the many cases of the tests below.
    private static let keys = Result { StableKeys(labels: try TestConfig.pipeline().entities) }
    private static let before = Result { try LabelledNumberVariants.before() }

    /// The keys in `text`, after the labels of the bundled configuration.
    private func detect(_ text: String) throws -> [StableKey] {
        try Self.keys.get().detect(in: text)
    }

    @Test("IBAN mod-97 accepts valid and rejects altered numbers")
    func iban() {
        #expect(StableKeys.isValidIBAN("PT50 0002 0123 1234 5678 9015 4"), "a Portuguese IBAN with its spaces passes mod-97")
        #expect(StableKeys.isValidIBAN("DE89 3704 0044 0532 0130 00"), "a German IBAN passes mod-97")
        #expect(StableKeys.isValidIBAN("GB82 WEST 1234 5698 7654 32"), "letters in the bank code count in base 36")
        #expect(!StableKeys.isValidIBAN("DE89 3704 0044 0532 0130 01"), "the IBAN's mod-97 check rejects a mistyped digit")
        #expect(!StableKeys.isValidIBAN("PT50 0002 0123 1234 5678 9015"), "an IBAN cut short of its country length is no IBAN")
        #expect(!StableKeys.isValidIBAN("XX00 1234"), "an unknown country code is no IBAN")
    }

    @Test("Portuguese NIF mod-11 with valid leading digits")
    func nif() {
        #expect(StableKeys.isValidPortugueseNIF("999999990"), "the NIF check digit accepts a valid number")
        #expect(StableKeys.isValidPortugueseNIF("501964843"), "a company NIPC starting with 5 is valid")
        #expect(StableKeys.isValidPortugueseNIF("999 999 990"), "a NIF written in groups is the same NIF")
        #expect(!StableKeys.isValidPortugueseNIF("999999991"), "the mod-11 check rejects a mistyped last digit")
        #expect(!StableKeys.isValidPortugueseNIF("123456780"), "a wrong check digit is rejected even with a valid leading digit")
        // Leading digit 4 alone (without the 45 prefix) is never assigned.
        #expect(!StableKeys.isValidPortugueseNIF("400000008"), "a leading digit no NIF is assigned is rejected")
        #expect(!StableKeys.isValidPortugueseNIF("12345678"), "a NIF has exactly 9 digits")
        // 123456789 is the textbook example: its check digit (9) satisfies mod-11, so it is checksum-valid.
        #expect(StableKeys.isValidPortugueseNIF("123456789"), "a checksum-valid number is accepted, however familiar")
    }

    @Test("Russian ИНН 10/12 digits, ОГРН and ОГРНИП checksums")
    func russianChecksums() {
        #expect(StableKeys.isValidRussianINN("7707083893"), "an organisation's 10-digit ИНН passes its checksum")
        #expect(!StableKeys.isValidRussianINN("7707083894"), "a mistyped 10-digit ИНН is rejected")
        #expect(StableKeys.isValidRussianINN("500100732259"), "an individual's 12-digit ИНН passes both check digits")
        #expect(!StableKeys.isValidRussianINN("500100732250"), "a wrong second check digit rejects a 12-digit ИНН")
        #expect(!StableKeys.isValidRussianINN("77070838"), "an ИНН has 10 or 12 digits")
        #expect(StableKeys.isValidOGRN("1027700132195"), "a 13-digit ОГРН passes mod 11")
        #expect(!StableKeys.isValidOGRN("1027700132194"), "a mistyped ОГРН is rejected")
        #expect(StableKeys.isValidOGRN("304500116000157"), "a 15-digit ОГРНИП passes mod 13")
        #expect(!StableKeys.isValidOGRN("304500116000158"), "a mistyped ОГРНИП is rejected")
        #expect(StableKeys.isValidRussianKPP("773601001"), "a КПП is tax office, reason and number")
        #expect(StableKeys.isValidRussianBIK("044525225"), "a Russian БИК starts with 04")
        #expect(!StableKeys.isValidRussianBIK("144525225"), "a БИК without the 04 country code is rejected")
    }

    @Test("EU VAT formats with country prefix")
    func vat() {
        #expect(StableKeys.isValidEUVAT("PT999999990"), "a Portuguese VAT number is a valid NIF with its prefix")
        #expect(!StableKeys.isValidEUVAT("PT999999991"), "a Portuguese VAT number must pass the NIF check digit")
        #expect(StableKeys.isValidEUVAT("DE123456789"), "a German VAT number is 9 digits after DE")
        #expect(StableKeys.isValidEUVAT("NL123456789B01"), "a Dutch VAT number carries its B suffix")
        #expect(!StableKeys.isValidEUVAT("DE12345678"), "a VAT number short of its country's format is rejected")
        #expect(!StableKeys.isValidEUVAT("US123456789"), "a country outside the EU has no EU VAT number")
    }

    @Test("Detects Russian requisites after their labels")
    func russianDetection() throws {
        let text = """
        ПАО Сбербанк, ИНН/КПП 7707083893/773601001, ОГРН 1027700132195
        БИК 044525225, р/с 40702810400000012345, к/с 30101810400000000225
        ИНН 7707083894 (ошибка)
        """
        let keys = Set(try detect(text).map(\.token))
        #expect(keys.contains("ruINN:7707083893"), "an ИНН written as ИНН/КПП is found")
        #expect(keys.contains("ruKPP:773601001"), "the КПП after the slash of ИНН/КПП is found")
        #expect(keys.contains("ruOGRN:1027700132195"), "an ОГРН after its label is found")
        #expect(keys.contains("ruBIK:044525225"), "a БИК after its label is found")
        #expect(keys.contains("ruAccount:40702810400000012345"), "a settlement account after р/с is found")
        #expect(keys.contains("ruAccount:30101810400000000225"), "a correspondent account after к/с is found")
        #expect(!keys.contains("ruINN:7707083894"), "a labelled ИНН that fails its checksum is not a key")
    }

    @Test("Detects IBAN, NIF and VAT; rejects invalid ones and unlabeled phone numbers")
    func europeanDetection() throws {
        let text = """
        IBAN: PT50 0002 0123 1234 5678 9015 4 BIC CGDIPTPL
        Wrong IBAN DE89 3704 0044 0532 0130 01
        NIF: 999 999 990 · Contribuinte n.º 123456780
        VAT No. PT 999999990 and supplier DE123456789
        Tel.: 912 345 678 · 213456789
        """
        let keys = try detect(text)
        let tokens = Set(keys.map(\.token))
        #expect(tokens.contains("iban:PT50000201231234567890154"), "an IBAN is found and kept without spaces")
        #expect(!tokens.contains { $0.hasPrefix("iban:DE") }, "an IBAN failing mod-97 is not a key")
        #expect(tokens.contains("ptNIF:999999990"), "a NIF after its label is found without spaces")
        #expect(!tokens.contains("ptNIF:123456780"), "a labelled NIF with a wrong check digit is not a key")
        #expect(tokens.contains("vatEU:PT999999990"), "a VAT number with a space after its prefix is found")
        #expect(tokens.contains("vatEU:DE123456789"), "a compact VAT number is found without a label")
        #expect(!tokens.contains { $0.contains("912345678") || $0.contains("213456789") }, "a phone number is not taken for a NIF")
        #expect(keys.count == Set(keys).count, "each key is reported once")
    }

    @Test("Labelled account, customer, policy and contract numbers in EN/RU/PT")
    func labelled() throws {
        let text = """
        Customer number: 12345678
        N.º de cliente: 1234 5678
        Apólice n.º AB-123456
        Policy No. PL/2024/0099
        Договор № 12/345-А от 01.01.2024
        Лицевой счёт 3456789
        Contrato de prestação de serviços
        """
        let tokens = Set(try detect(text).map(\.token))
        #expect(tokens.contains("accountNumber:12345678"), "EN and PT customer numbers are one key, spaces removed")
        #expect(tokens.contains("policyOrContract:AB-123456"), "a Portuguese policy number after Apólice n.º is found")
        #expect(tokens.contains("policyOrContract:PL/2024/0099"), "an English policy number keeps its slashes")
        #expect(tokens.contains("policyOrContract:12/345-А"), "a Russian contract number stops before its date")
        #expect(tokens.contains("accountNumber:3456789"), "a Russian personal account after Лицевой счёт is found")
        #expect(!tokens.contains { $0.contains("PRESTA") }, "a word after a label is never taken for a number")
    }

    @Test("An account or policy number is the one after a word the configuration lists, entities.accountLabels and policyLabels")
    func labelsFromConfiguration() throws {
        var labels = try TestConfig.pipeline().entities
        labels.accountLabels = ["Kundennummer"]
        labels.policyLabels = ["Vertragsnummer"]
        let text = "Kundennummer: 4711 0815\nVertragsnummer VN-2024-7781\nCustomer number: 12345678"
        let tokens = StableKeys(labels: labels).detect(in: text).map(\.token)
        #expect(tokens == ["accountNumber:47110815", "policyOrContract:VN-2024-7781"],
                "a label added to the configuration is read in any language, and one taken out no longer is")
    }

    /// The labelled numbers the patterns of 429517b did not find, or read otherwise, and the configured labels find:
    /// each a number after a contract's title and an N sign that no digit follows at once (`договор аренды Nº: 12`,
    /// `договор No AB-12`, `договор N°AB-12`, `Договор N 2024/15`), which the old rule's look-ahead for a digit left out;
    /// and a number written against N (`Договор N12/2024`), which it read with its N.
    private static let foundSince: [String: [String]] = {
        var found: [String: [String]] = [:]
        for title in LabelledNumberVariants.contractTitles {
            for sign in [" N"] + LabelledNumberVariants.contractSigns {
                for separator in LabelledNumberVariants.separators {
                    for number in LabelledNumberVariants.numbers {
                        let digitFirst = number.first?.isNumber == true
                        // As before: a letter against a sign that ends in a letter, and a number that a digit begins
                        // after any sign but N alone, with a space or none between.
                        if separator.isEmpty, !digitFirst, sign.hasSuffix("N") || sign.hasSuffix("o") { continue }
                        if sign != " N", digitFirst, separator != ": " { continue }
                        found["Texto договор\(title)\(sign)\(separator)\(number) fim"] = ["policyOrContract:\(number)"]
                    }
                }
            }
        }
        found["Договор N 2024/15"] = ["policyOrContract:2024/15"]
        found["Договор N12/2024"] = ["policyOrContract:12/2024"]
        return found
    }()

    /// The labelled numbers the patterns of 429517b found and the configured labels do not, by design: a letter written
    /// against a label whose phrase ends in a letter (`customer idAB-12`, `договорN12`), where no reader can tell where
    /// the label ends. A phrase that ends in a dot (`account no.`) or a sign (`№`, `nº`) may run into what follows.
    private static func lostSince(label: String, separator: String, number: String) throws -> Bool {
        guard separator.isEmpty else { return false }
        // N written against a contract's title, which the old rule read as the first letter of its number.
        if label.hasSuffix("N"), !label.hasSuffix(" N") { return true }
        guard number.first?.isLetter == true else { return false }
        let spelled = try phrases.get().filter { $0.regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil }
        return !spelled.isEmpty && spelled.allSatisfy { phrase in
            phrase.text.last.map { ($0.isLetter || $0.isNumber) && !"ºª".contains($0) } ?? false
        }
    }

    /// Each account and policy phrase of the configuration, and what matches it whole.
    private static let phrases = Result {
        let entities = try TestConfig.pipeline().entities
        return (entities.accountLabels + entities.policyLabels).compactMap { phrase in
            LabelPhrases.alternation([phrase]).map { (text: phrase, regex: LabelPhrases.regex("^" + $0 + "$")) }
        }
    }

    @Test("Each label of the configuration finds the numbers its pattern of 429517b found, written in every way it allowed",
          arguments: LabelledNumberVariants.accountLabels + LabelledNumberVariants.policyLabels)
    func asBefore(label: String) throws {
        let before = try Self.before.get()
        for separator in LabelledNumberVariants.separators {
            for number in LabelledNumberVariants.numbers {
                let text = "Texto \(label)\(separator)\(number) fim"
                let found = try detect(text).map(\.token)
                let old = try #require(before[text], "the old patterns' keys were captured for \(text)")
                let expected = try Self.lostSince(label: label, separator: separator, number: number) ? [] : Self.foundSince[text] ?? old
                #expect(found == expected, "\(text): the keys of 429517b \(old), those the old look-ahead missed, and none glued to a word")
            }
        }
    }

    @Test("In sentences, a label takes the number after it, and never a word that starts with N", arguments: LabelledNumberVariants.sentences)
    func sentencesAsBefore(sentence: String) throws {
        let before = try Self.before.get()
        let expected = try #require(Self.foundSince[sentence] ?? before[sentence], "the old patterns' keys were captured for \(sentence)")
        #expect(try detect(sentence).map(\.token) == expected, "\(sentence): as 429517b found, or found since")
    }

    @Test("A number found since is one the old patterns missed or read with its N, and the variants miss none they found")
    func foundSinceIsAllThatChanged() throws {
        let before = try Self.before.get()
        for (text, found) in Self.foundSince {
            let old = try #require(before[text], "\(text) is a variant whose old keys were captured")
            #expect(old.isEmpty || old.first?.hasPrefix("policyOrContract:N12/") == true,
                    "\(text): only what the old patterns missed or misread, \(old) → \(found)")
        }
        #expect(Self.foundSince.count == 82, "a number after an N sign that no digit follows at once, for each title, sign and separator")
        #expect(Set(before.keys) == Set((LabelledNumberVariants.accountLabels + LabelledNumberVariants.policyLabels)
                    .flatMap(LabelledNumberVariants.texts(for:)) + LabelledNumberVariants.sentences),
                "the captured keys are of exactly these variants")
    }

    @Test("A label, a number sign or a list of them that cannot be matched is refused by name")
    func phraseProblems() throws {
        var config = try TestConfig.pipeline()
        config.entities.policyLabels.append("* *")
        config.entities.accountLabels.append("cliente * * * * nº")
        config.entities.numberSigns.append("n *")
        #expect(config.problems == [
            #"entities.accountLabels: "cliente * * * * nº" has more than 3 of *"#,
            #"entities.policyLabels: "* *" has no word of its own besides *"#,
            #"entities.numberSigns: "n *" holds *, and a number sign is written as it is"#,
        ], "a phrase of any word alone would take every number for a policy; \(config.problems)")
    }

    @Test("A 20-digit account after л/с is reported once, as the specific kind")
    func deduplication() throws {
        let keys = try detect("л/с 40702810400000012345; л/с 40702810400000012345")
        #expect(keys.map(\.token) == ["ruAccount:40702810400000012345"], "a repeated account is one key of its specific kind, not also a generic number")
    }

    @Test("Normalisation strips whitespace and uppercases")
    func normalize() {
        #expect(StableKeys.normalize(" pt50 0002\u{00A0}0123 ") == "PT5000020123", "spaces, no-break spaces included, go and letters are uppercased")
        #expect(StableKeys.normalize("AB-123.") == "AB-123", "a trailing full stop is punctuation, not part of the number")
    }
}
