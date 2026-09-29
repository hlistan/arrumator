import ArrumatorCore
import Testing

@Suite("Stable keys")
struct StableKeysTests {
    @Test("IBAN mod-97 accepts valid and rejects altered numbers")
    func iban() {
        #expect(StableKeys.isValidIBAN("PT50 0002 0123 1234 5678 9015 4"))
        #expect(StableKeys.isValidIBAN("DE89 3704 0044 0532 0130 00"))
        #expect(StableKeys.isValidIBAN("GB82 WEST 1234 5698 7654 32"))
        #expect(!StableKeys.isValidIBAN("DE89 3704 0044 0532 0130 01"))
        #expect(!StableKeys.isValidIBAN("PT50 0002 0123 1234 5678 9015"))
        #expect(!StableKeys.isValidIBAN("XX00 1234"))
    }

    @Test("Portuguese NIF mod-11 with valid leading digits")
    func nif() {
        #expect(StableKeys.isValidPortugueseNIF("999999990"))
        #expect(StableKeys.isValidPortugueseNIF("501964843"))
        #expect(StableKeys.isValidPortugueseNIF("999 999 990"))
        #expect(!StableKeys.isValidPortugueseNIF("999999991"))
        #expect(!StableKeys.isValidPortugueseNIF("123456780"))
        // Leading digit 4 alone (without the 45 prefix) is never assigned.
        #expect(!StableKeys.isValidPortugueseNIF("400000008"))
        #expect(!StableKeys.isValidPortugueseNIF("12345678"))
        // 123456789 is the textbook example: its check digit (9) satisfies mod-11, so it is checksum-valid.
        #expect(StableKeys.isValidPortugueseNIF("123456789"))
    }

    @Test("Russian ИНН 10/12 digits, ОГРН and ОГРНИП checksums")
    func russianChecksums() {
        #expect(StableKeys.isValidRussianINN("7707083893"))
        #expect(!StableKeys.isValidRussianINN("7707083894"))
        #expect(StableKeys.isValidRussianINN("500100732259"))
        #expect(!StableKeys.isValidRussianINN("500100732250"))
        #expect(!StableKeys.isValidRussianINN("77070838"))
        #expect(StableKeys.isValidOGRN("1027700132195"))
        #expect(!StableKeys.isValidOGRN("1027700132194"))
        #expect(StableKeys.isValidOGRN("304500116000157"))
        #expect(!StableKeys.isValidOGRN("304500116000158"))
        #expect(StableKeys.isValidRussianKPP("773601001"))
        #expect(StableKeys.isValidRussianBIK("044525225"))
        #expect(!StableKeys.isValidRussianBIK("144525225"))
    }

    @Test("EU VAT formats with country prefix")
    func vat() {
        #expect(StableKeys.isValidEUVAT("PT999999990"))
        #expect(!StableKeys.isValidEUVAT("PT999999991"))
        #expect(StableKeys.isValidEUVAT("DE123456789"))
        #expect(StableKeys.isValidEUVAT("NL123456789B01"))
        #expect(!StableKeys.isValidEUVAT("DE12345678"))
        #expect(!StableKeys.isValidEUVAT("US123456789"))
    }

    @Test("Detects Russian requisites after their labels")
    func russianDetection() {
        let text = """
        ПАО Сбербанк, ИНН/КПП 7707083893/773601001, ОГРН 1027700132195
        БИК 044525225, р/с 40702810400000012345, к/с 30101810400000000225
        ИНН 7707083894 (ошибка)
        """
        let keys = Set(StableKeys.detect(in: text).map(\.token))
        #expect(keys.contains("ruINN:7707083893"))
        #expect(keys.contains("ruKPP:773601001"))
        #expect(keys.contains("ruOGRN:1027700132195"))
        #expect(keys.contains("ruBIK:044525225"))
        #expect(keys.contains("ruAccount:40702810400000012345"))
        #expect(keys.contains("ruAccount:30101810400000000225"))
        #expect(!keys.contains("ruINN:7707083894"))
    }

    @Test("Detects IBAN, NIF and VAT; rejects invalid ones and unlabeled phone numbers")
    func europeanDetection() {
        let text = """
        IBAN: PT50 0002 0123 1234 5678 9015 4 BIC CGDIPTPL
        Wrong IBAN DE89 3704 0044 0532 0130 01
        NIF: 999 999 990 · Contribuinte n.º 123456780
        VAT No. PT 999999990 and supplier DE123456789
        Tel.: 912 345 678 · 213456789
        """
        let keys = StableKeys.detect(in: text)
        let tokens = Set(keys.map(\.token))
        #expect(tokens.contains("iban:PT50000201231234567890154"))
        #expect(!tokens.contains { $0.hasPrefix("iban:DE") })
        #expect(tokens.contains("ptNIF:999999990"))
        #expect(!tokens.contains("ptNIF:123456780"))
        #expect(tokens.contains("vatEU:PT999999990"))
        #expect(tokens.contains("vatEU:DE123456789"))
        #expect(!tokens.contains { $0.contains("912345678") || $0.contains("213456789") })
        #expect(keys.count == Set(keys).count)
    }

    @Test("Labelled account, customer, policy and contract numbers in EN/RU/PT")
    func labelled() {
        let text = """
        Customer number: 12345678
        N.º de cliente: 1234 5678
        Apólice n.º AB-123456
        Policy No. PL/2024/0099
        Договор № 12/345-А от 01.01.2024
        Лицевой счёт 3456789
        Contrato de prestação de serviços
        """
        let tokens = Set(StableKeys.detect(in: text).map(\.token))
        #expect(tokens.contains("accountNumber:12345678"))
        #expect(tokens.contains("policyOrContract:AB-123456"))
        #expect(tokens.contains("policyOrContract:PL/2024/0099"))
        #expect(tokens.contains("policyOrContract:12/345-А"))
        #expect(tokens.contains("accountNumber:3456789"))
        #expect(!tokens.contains { $0.contains("PRESTA") })
    }

    @Test("A 20-digit account after л/с is reported once, as the specific kind")
    func deduplication() {
        let keys = StableKeys.detect(in: "л/с 40702810400000012345; л/с 40702810400000012345")
        #expect(keys.map(\.token) == ["ruAccount:40702810400000012345"])
    }

    @Test("Normalisation strips whitespace and uppercases")
    func normalize() {
        #expect(StableKeys.normalize(" pt50 0002\u{00A0}0123 ") == "PT5000020123")
        #expect(StableKeys.normalize("AB-123.") == "AB-123")
    }
}
