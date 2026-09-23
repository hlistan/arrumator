import Foundation

/// SplitMix64 (Steele, Lea & Flood, 2014): tiny, fast and fully specified, so a seed produces the same
/// stream on every machine and toolchain. The standard library's `random(in:using:)` is avoided on purpose
/// because its reduction algorithm is an implementation detail.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 64-bit FNV-1a, used to derive independent per-fixture streams from one corpus seed.
enum FNV1a {
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// Seeded source of fake but checksum-valid data. Each fixture gets its own stream (`salt` = file path), so
/// adding or reordering fixtures never changes the bytes of the others.
struct Fake: Sendable {
    /// The canonical test NIF (valid mod-11 check digit, never issued to a person).
    static let canonicalNIF = "999999990"
    /// The canonical sample IBAN, printed in groups as on real documents.
    static let canonicalIBAN = "PT50 0002 0123 1234 5678 9015 4"
    /// A nine-digit number that fails the NIF check. Note that the often-quoted "123456789" is in fact valid.
    static let invalidNIF = "123456780"

    private var generator: SplitMix64

    init(seed: UInt64, salt: String) {
        generator = SplitMix64(seed: seed ^ FNV1a.hash(salt))
    }

    mutating func next() -> UInt64 { generator.next() }

    /// Uniform integer in `range` (Lemire's multiply-high reduction; the bias is below 2^-40 for our spans).
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next().multipliedFullWidth(by: span).high)
    }

    /// Uniform double in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }

    mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    /// Triangular noise in [-1, 1], peaked at zero (sum of two uniforms).
    mutating func triangular() -> Double { unit() + unit() - 1 }

    mutating func sign() -> Double { next() & 1 == 0 ? 1 : -1 }

    mutating func pick<Element>(_ items: [Element]) -> Element {
        precondition(!items.isEmpty, "pick from an empty list")
        return items[int(0...(items.count - 1))]
    }

    mutating func digits(_ count: Int) -> [Int] { (0..<count).map { _ in int(0...9) } }

    mutating func digitString(_ count: Int) -> String { digits(count).map(String.init).joined() }

    mutating func letters(_ count: Int, from alphabet: String = "ABCDEFGHJKLMNPQRSTUVWXYZ") -> String {
        let pool = Array(alphabet)
        return String((0..<count).map { _ in pick(pool) })
    }

    mutating func hex(_ count: Int) -> String {
        let pool = Array("0123456789abcdef")
        return String((0..<count).map { _ in pick(pool) })
    }

    /// Money amount with whole cents, uniformly drawn from `range` (in currency units).
    mutating func money(_ range: ClosedRange<Double>) -> Money {
        Money(cents: int(Int((range.lowerBound * 100).rounded())...Int((range.upperBound * 100).rounded())))
    }

    /// A reference number that cannot be mistaken for a checksum-valid NIF or ИНН, so extractor tests
    /// know exactly which identifiers a document contains.
    mutating func reference(_ count: Int) -> String {
        while true {
            let candidate = digitString(count)
            if !Checksum.isValidPTNIF(candidate) && !Checksum.isValidRUINN(candidate) && candidate.first != "0" {
                return candidate
            }
        }
    }

    // MARK: Identifiers with real checksums

    /// Portuguese NIF/NIPC; `firstDigit` 1–3 for people, 5 for companies.
    mutating func ptNIF(firstDigit: Int) -> String {
        let body = [firstDigit] + digits(7)
        return (body + [Checksum.ptNIFCheckDigit(body)]).map(String.init).joined()
    }

    /// Portuguese social-security number (NISS), 11 digits starting with 1 for people.
    mutating func niss() -> String {
        let body = [1] + digits(9)
        return (body + [Checksum.nissCheckDigit(body)]).map(String.init).joined()
    }

    /// Russian ИНН: 12 digits for people, 10 for organisations; `region` is the two-digit tax region code.
    mutating func ruINN(region: Int, organisation: Bool) -> String {
        let regionDigits = [region / 10, region % 10]
        if organisation {
            let body = regionDigits + digits(7)
            return (body + [Checksum.innDigit(body, weights: Checksum.inn10Weights)]).map(String.init).joined()
        }
        let body = regionDigits + digits(8)
        let first = Checksum.innDigit(body, weights: Checksum.inn11Weights)
        let second = Checksum.innDigit(body + [first], weights: Checksum.inn12Weights)
        return (body + [first, second]).map(String.init).joined()
    }

    /// Russian СНИЛС formatted as "XXX-XXX-XXX YY".
    mutating func snils() -> String {
        let body = [int(1...9)] + digits(8)
        let text = body.map(String.init).joined()
        let check = String(format: "%02d", Checksum.snilsCheck(body))
        return "\(text.prefix(3))-\(text.dropFirst(3).prefix(3))-\(text.dropFirst(6)) \(check)"
    }

    /// Russian 20-digit account with a valid control key for the given 9-digit БИК.
    mutating func ruAccount(prefix: String, bik: String) -> String {
        var account = prefix.compactMap(\.wholeNumberValue) + digits(20 - prefix.count)
        account[8] = 0
        account[8] = Checksum.ruAccountKey(bik: bik, account: account)
        return account.map(String.init).joined()
    }

    /// IBAN with valid mod-97 check digits, formatted in groups of four.
    mutating func iban(country: String, bban: String) -> String {
        IBAN.grouped(country + Checksum.ibanCheckDigits(country: country, bban: bban) + bban)
    }

    /// Portuguese IBAN: bank, branch and account followed by the two NIB check digits.
    mutating func portugueseIBAN(bank: String) -> String {
        let body = bank + digitString(15)
        return iban(country: "PT", bban: body + String(format: "%02d", 98 - Checksum.mod97(body + "00")))
    }

    /// Belgian IBAN: bank and account followed by the national mod-97 check (97 when the remainder is 0).
    mutating func belgianIBAN(bank: String) -> String {
        let body = bank + digitString(10 - bank.count)
        let check = Checksum.mod97(body)
        return iban(country: "BE", bban: body + String(format: "%02d", check == 0 ? 97 : check))
    }
}

enum IBAN {
    static func grouped(_ compact: String) -> String {
        var groups: [String] = []
        var rest = Substring(compact)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: " ")
    }

    static func compact(_ grouped: String) -> String {
        grouped.filter { !$0.isWhitespace }.uppercased()
    }
}

/// Check-digit algorithms of the identifiers embedded in fixtures.
enum Checksum {
    static let inn10Weights = [2, 4, 10, 3, 5, 9, 4, 6, 8]
    static let inn11Weights = [7, 2, 4, 10, 3, 5, 9, 4, 6, 8]
    static let inn12Weights = [3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8]

    /// NIF: weights 9…2 over the first eight digits; remainder 0 or 1 gives 0, otherwise 11 − remainder.
    static func ptNIFCheckDigit(_ first8: [Int]) -> Int {
        let sum = zip(first8, (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 }
        let remainder = sum % 11
        return remainder < 2 ? 0 : 11 - remainder
    }

    /// Mod-11 validity with any non-zero leading digit: stricter than issuing rules, so generated reference
    /// numbers never pass for a NIF under any extractor's prefix table.
    static func isValidPTNIF(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard text.count == 9, digits.count == 9, digits[0] != 0 else { return false }
        return ptNIFCheckDigit(Array(digits.prefix(8))) == digits[8]
    }

    /// NISS: weights 29, 23, 19, 17, 13, 11, 7, 5, 3, 2; check = 9 − (sum mod 10).
    static func nissCheckDigit(_ first10: [Int]) -> Int {
        let weights = [29, 23, 19, 17, 13, 11, 7, 5, 3, 2]
        return 9 - zip(first10, weights).reduce(0) { $0 + $1.0 * $1.1 } % 10
    }

    static func innDigit(_ digits: [Int], weights: [Int]) -> Int {
        zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10
    }

    static func isValidRUINN(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard digits.count == text.count else { return false }
        switch digits.count {
        case 10:
            return innDigit(Array(digits.prefix(9)), weights: inn10Weights) == digits[9]
        case 12:
            return innDigit(Array(digits.prefix(10)), weights: inn11Weights) == digits[10]
                && innDigit(Array(digits.prefix(11)), weights: inn12Weights) == digits[11]
        default:
            return false
        }
    }

    /// ISO 13616: move the country code and "00" to the end, letters to numbers, 98 − (n mod 97).
    static func ibanCheckDigits(country: String, bban: String) -> String {
        String(format: "%02d", 98 - mod97(bban + country + "00"))
    }

    static func isValidIBAN(_ text: String) -> Bool {
        let compact = IBAN.compact(text)
        guard compact.count >= 15 else { return false }
        return mod97(String(compact.dropFirst(4) + compact.prefix(4))) == 1
    }

    static func mod97(_ text: String) -> Int {
        var remainder = 0
        for character in text {
            let value = character.isLetter ? Int(character.asciiValue! - Character("A").asciiValue!) + 10
                : character.wholeNumberValue!
            for digit in String(value) {
                remainder = (remainder * 10 + digit.wholeNumberValue!) % 97
            }
        }
        return remainder
    }

    /// СНИЛС: weights 9…1; sums below 100 are the check, 100/101 give 00, larger sums are reduced mod 101.
    static func snilsCheck(_ nine: [Int]) -> Int {
        let sum = zip(nine, (1...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 }
        let reduced = sum > 101 ? sum % 101 : sum
        return reduced >= 100 ? 0 : reduced
    }

    /// Russian account control key over the last three БИК digits and the account (weights 7, 1, 3).
    static func ruAccountKey(bik: String, account: [Int]) -> Int {
        let sequence = bik.suffix(3).compactMap(\.wholeNumberValue) + account
        let weights = [7, 1, 3]
        let sum = sequence.enumerated().reduce(0) { $0 + ($1.element * weights[$1.offset % 3]) % 10 }
        return (sum % 10) * 3 % 10
    }

    static func isValidRUAccount(_ account: String, bik: String) -> Bool {
        let sequence = bik.suffix(3).compactMap(\.wholeNumberValue) + account.compactMap(\.wholeNumberValue)
        let weights = [7, 1, 3]
        return sequence.enumerated().reduce(0) { $0 + ($1.element * weights[$1.offset % 3]) % 10 } % 10 == 0
    }

    /// ICAO 9303 machine-readable-zone check digit (weights 7, 3, 1; letters A=10…Z=35; filler = 0).
    static func mrzCheckDigit(_ field: String) -> Int {
        let weights = [7, 3, 1]
        return field.enumerated().reduce(0) { sum, item in
            let value: Int
            if let digit = item.element.wholeNumberValue {
                value = digit
            } else if item.element.isLetter, let ascii = item.element.asciiValue {
                value = Int(ascii - Character("A").asciiValue!) + 10
            } else {
                value = 0
            }
            return sum + value * weights[item.offset % 3]
        } % 10
    }
}
