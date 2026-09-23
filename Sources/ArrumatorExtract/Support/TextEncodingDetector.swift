import Foundation

/// Decoded text plus how its encoding was determined.
struct DecodedText: Sendable {
    enum Method: String, Sendable, Encodable {
        case byteOrderMark, strictUTF8, detected, cyrillicBigrams, lossyFallback
    }

    var text: String
    var encoding: String.Encoding
    var method: Method

    /// IANA charset name (`utf-8`, `windows-1251`, `koi8-r`) for metadata and traces.
    var encodingName: String { TextEncodingDetector.ianaName(encoding) }
    /// True when the encoding was inferred rather than declared or proven.
    var isGuess: Bool { method != .byteOrderMark && method != .strictUTF8 }
}

/// Decodes text of unknown encoding: BOM → strict UTF-8 → `NSString` detection over the configured candidate
/// encodings → Russian plausibility across the Cyrillic single-byte candidates (CP1251 vs KOI8-R vs Mac
/// Cyrillic, see `russianPlausibility`). The last step matters because `NSString` reads KOI8-R text as Latin-1.
struct TextEncodingDetector: Sendable {
    let candidates: [String.Encoding]
    let sampleChars: Int
    let cyrillicMinShare: Double

    init(candidateNames: [String], sampleChars: Int, cyrillicMinShare: Double) {
        candidates = candidateNames.compactMap(Self.encoding(named:))
        self.sampleChars = sampleChars
        self.cyrillicMinShare = cyrillicMinShare
    }

    func decode(_ data: Data, truncatedRead: Bool) -> DecodedText {
        if let bom = Self.decodeBOM(data) { return bom }
        if let utf8 = Self.strictUTF8(data, allowCutTail: truncatedRead) {
            return DecodedText(text: utf8, encoding: .utf8, method: .strictUTF8)
        }
        let detected = detectWithNSString(data)
        if let cyrillic = bestCyrillic(data, current: detected) { return cyrillic }
        if let detected { return detected }
        return DecodedText(text: String(decoding: data, as: UTF8.self), encoding: .utf8, method: .lossyFallback)
    }

    // MARK: Steps

    private static func decodeBOM(_ data: Data) -> DecodedText? {
        let boms: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (bom, encoding) in boms where data.starts(with: bom) {
            guard let text = String(data: data.dropFirst(bom.count), encoding: encoding) else { continue }
            return DecodedText(text: text, encoding: encoding, method: .byteOrderMark)
        }
        return nil
    }

    /// Strict UTF-8; when the read was capped, up to three trailing bytes of a cut sequence are ignored.
    private static func strictUTF8(_ data: Data, allowCutTail: Bool) -> String? {
        let maxCut = allowCutTail ? min(3, data.count) : 0
        for cut in 0...maxCut {
            if let text = String(validating: data.dropLast(cut), as: UTF8.self) { return text }
        }
        return nil
    }

    private func detectWithNSString(_ data: Data) -> DecodedText? {
        var converted: NSString?
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: candidates.map { NSNumber(value: $0.rawValue) },
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        guard raw != 0, let converted else { return nil }
        return DecodedText(text: converted as String, encoding: String.Encoding(rawValue: raw), method: .detected)
    }

    /// The Cyrillic candidate whose decoding reads most like Russian, if it clears `cyrillicMinShare` and beats
    /// the detected decoding.
    private func bestCyrillic(_ data: Data, current: DecodedText?) -> DecodedText? {
        let currentScore = current.map { Self.russianPlausibility(String($0.text.prefix(sampleChars))) } ?? 0
        var best: (text: DecodedText, score: Double)?
        for encoding in candidates where Self.isCyrillicSingleByte(encoding) {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let score = Self.russianPlausibility(String(text.prefix(sampleChars)))
            if score > (best?.score ?? 0) {
                best = (DecodedText(text: text, encoding: encoding, method: .cyrillicBigrams), score)
            }
        }
        guard let best, best.score >= cyrillicMinShare, best.score > currentScore else { return nil }
        if let current, current.encoding == best.text.encoding { return current }
        return best.text
    }

    // MARK: Russian plausibility

    /// How much `text` reads like Russian: frequent Russian letter bigrams minus lowercase→uppercase flips inside
    /// words, per visible character. Mixing up KOI8-R and CP1251 both scrambles the letters and inverts their case
    /// (`рТЙЧЕФ` for `Привет`), so the wrong decoding scores far lower even on short samples.
    static func russianPlausibility(_ text: String) -> Double {
        var visible = 0
        var common = 0
        var caseFlips = 0
        var previous: Character?
        for char in text {
            if !char.isWhitespace { visible += 1 }
            guard char.isLetter else {
                previous = nil
                continue
            }
            if let prev = previous {
                if prev.isLowercase, char.isUppercase { caseFlips += 1 }
                if prev.isCyrillic, char.isCyrillic, commonRussianBigrams.contains(String([prev, char]).lowercased()) {
                    common += 1
                }
            }
            previous = char
        }
        return visible == 0 ? 0 : Double(common - caseFlips) / Double(visible)
    }

    /// The most frequent Russian letter bigrams (national corpus frequency lists).
    private static let commonRussianBigrams: Set<String> = [
        "ст", "но", "то", "на", "ен", "ов", "ни", "ра", "во", "ко", "ал", "ро", "пр", "по", "ор", "ер", "ан", "ре",
        "ос", "ет", "от", "ла", "не", "ол", "ка", "ли", "ва", "ит", "ть", "ел", "ом", "ес", "ле", "та", "ль", "ин",
        "ие", "де", "го", "ат", "ий", "ск", "ый", "ой", "ая", "ед", "ак", "ам", "ме", "ас", "ве", "да", "ил", "ри",
        "те", "об", "ег", "ад", "ую", "ся", "ем", "ти", "ны", "ми", "ых", "их", "ку", "ду", "тв", "зн", "ча", "че",
        "чи", "ще", "жи", "ши", "же", "ше", "уч", "лю", "ря", "мо", "мы", "ма", "ги", "бо", "бы",
    ]

    // MARK: Encodings

    /// Maps configuration names (`windowsCP1251`, `koi8R`, `macCyrillic`, …) or IANA charset names to encodings.
    static func encoding(named name: String) -> String.Encoding? {
        let foundation: [String: String.Encoding] = [
            "utf8": .utf8, "utf16": .utf16, "ascii": .ascii, "isoLatin1": .isoLatin1, "isoLatin2": .isoLatin2,
            "windowsCP1250": .windowsCP1250, "windowsCP1251": .windowsCP1251, "windowsCP1252": .windowsCP1252,
            "macOSRoman": .macOSRoman,
        ]
        if let encoding = foundation[name] { return encoding }
        let coreFoundation: [String: CFStringEncoding] = [
            "koi8R": CFStringEncoding(CFStringEncodings.KOI8_R.rawValue),
            "koi8U": CFStringEncoding(CFStringEncodings.KOI8_U.rawValue),
            "macCyrillic": CFStringEncoding(CFStringEncodings.macCyrillic.rawValue),
            "isoLatinCyrillic": CFStringEncoding(CFStringEncodings.isoLatinCyrillic.rawValue),
            "dosRussian": CFStringEncoding(CFStringEncodings.dosRussian.rawValue),
        ]
        let cf = coreFoundation[name] ?? CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func ianaName(_ encoding: String.Encoding) -> String {
        let cf = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        return (CFStringConvertEncodingToIANACharSetName(cf) as String?) ?? String(encoding.rawValue)
    }

    private static let cyrillicSingleByte: Set<CFStringEncoding> = [
        CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue),
        CFStringEncoding(CFStringEncodings.KOI8_R.rawValue),
        CFStringEncoding(CFStringEncodings.KOI8_U.rawValue),
        CFStringEncoding(CFStringEncodings.macCyrillic.rawValue),
        CFStringEncoding(CFStringEncodings.isoLatinCyrillic.rawValue),
        CFStringEncoding(CFStringEncodings.dosRussian.rawValue),
    ]

    static func isCyrillicSingleByte(_ encoding: String.Encoding) -> Bool {
        cyrillicSingleByte.contains(CFStringConvertNSStringEncodingToEncoding(encoding.rawValue))
    }
}

extension Character {
    var isCyrillic: Bool {
        unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }
}
