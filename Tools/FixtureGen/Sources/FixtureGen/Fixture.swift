import Foundation

enum Language: String, Decodable, Sendable {
    case pt, ru, en
    /// Undetermined: the file carries no readable language (blank scan).
    case und
}

/// Physical form of a fixture (the `kind` field of expected.json).
enum FixtureKind: String, Decodable, Sendable {
    case pdfText = "pdf-text"
    case pdfScan = "pdf-scan"
    case imagePhoto = "image-photo"
    case imageScreenshot = "image-screenshot"
    case docx, xlsx, text, eml
}

/// Lowest acceptable confidence band: `auto` must auto-file, `check` may also be flagged, `review` accepts anything.
enum Band: String, Decodable, Sendable {
    case auto, check, review
}

/// The app's `document_type` vocabulary.
enum DocType: String, Decodable, Sendable {
    case idDocument = "id-document"
    case certificate, attestation, contract, invoice, receipt, statement
    case taxReturn = "tax-return"
    case taxAssessment = "tax-assessment"
    case payslip, letter, application, policy
    case medicalReport = "medical-report"
    case prescription, ticket, license, manual, quote, legal, other

    /// English Title Case label used in renamed files.
    var label: String {
        switch self {
        case .idDocument: "ID Document"
        case .taxReturn: "Tax Return"
        case .taxAssessment: "Tax Assessment"
        case .medicalReport: "Medical Report"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// Soft extraction warnings the app is expected to raise (raw values match the app's `WarningCode`).
enum WarningCode: String, Decodable, Sendable {
    case encrypted, corrupted, encodingGuessed, emptyText
}

enum TextEncoding: String, Decodable, Sendable {
    case utf8 = "utf-8"
    case koi8r = "koi8-r"

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .koi8r: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
        }
    }
}

/// A stable key as the app tokenises it (`kind:value`).
enum Identifier: Sendable, Hashable {
    case ptNIF(String)
    case ruINN(String)
    case iban(String)

    var token: String {
        switch self {
        case .ptNIF(let value): "ptNIF:\(value)"
        case .ruINN(let value): "ruINN:\(value)"
        case .iban(let value): "iban:\(IBAN.compact(value))"
        }
    }

    /// Tokens for standalone digit runs that pass the NIF (9 digits) or ИНН (10/12 digits) checksum.
    static func checksumValidTokens(in text: String) -> Set<String> {
        var tokens: Set<String> = []
        // Greedy runs are maximal, so a 20-digit account never yields a 9-digit sub-match.
        for match in text.matches(of: /[0-9]+/) where (9...12).contains(match.output.count) {
            let run = String(match.output)
            if run.count == 9, Checksum.isValidPTNIF(run) {
                tokens.insert(Identifier.ptNIF(run).token)
            } else if Checksum.isValidRUINN(run) {
                tokens.insert(Identifier.ruINN(run).token)
            }
        }
        return tokens
    }

    var isChecksumValid: Bool {
        switch self {
        case .ptNIF(let value): Checksum.isValidPTNIF(value)
        case .ruINN(let value): Checksum.isValidRUINN(value)
        case .iban(let value): Checksum.isValidIBAN(value)
        }
    }
}

struct Expected: Decodable, Sendable {
    let category: String
    let yearFolder: String?
    let docType: DocType?
    let correspondent: String?
    let date: String?
    let titleContains: [String]
    let identifiers: [String]
    let renamed: String?
    let minBand: Band
    let warnings: [WarningCode]?

    /// Absent values are explicit nulls, except `warnings`, which only appears when non-empty.
    var json: JSON {
        var members: [(String, JSON)] = [
            ("category", .string(category)),
            ("year_folder", yearFolder.json { .string($0) }),
            ("doc_type", docType.json { .string($0.rawValue) }),
            ("correspondent", correspondent.json { .string($0) }),
            ("date", date.json { .string($0) }),
            ("title_contains", .array(titleContains.map { .string($0) })),
            ("identifiers", .array(identifiers.map { .string($0) })),
            ("renamed", renamed.json { .string($0) }),
            ("min_band", .string(minBand.rawValue)),
        ]
        if let warnings {
            members.append(("warnings", .array(warnings.map { .string($0.rawValue) })))
        }
        return .object(members)
    }
}

/// Alternative answers that still count as a pass (ambiguous items).
struct AcceptAlso: Decodable, Sendable {
    var category: [String]?
    var yearFolder: [String]?
    var docType: [DocType]?
    var correspondent: [String]?

    var json: JSON {
        let members: [(String, [String]?)] = [
            ("category", category), ("year_folder", yearFolder), ("doc_type", docType?.map(\.rawValue)),
            ("correspondent", correspondent),
        ]
        return .object(members.compactMap { key, values in values.map { (key, .array($0.map { .string($0) })) } })
    }

    init(category: [String]? = nil, yearFolder: [String]? = nil, docType: [DocType]? = nil, correspondent: [String]? = nil) {
        self.category = category
        self.yearFolder = yearFolder
        self.docType = docType
        self.correspondent = correspondent
    }
}

/// One entry of expected.json.
struct FixtureRecord: Decodable, Sendable {
    let file: String
    let lang: Language
    let kind: FixtureKind
    let core: Bool
    let expected: Expected
    let acceptAlso: AcceptAlso?
    /// For the duplicate fixture: the file it is a byte-identical copy of.
    let duplicateOf: String?
    /// For text fixtures: the byte encoding on disk.
    let encoding: TextEncoding?
    /// For the encrypted fixture: the user password (the app must not know it).
    let password: String?
    /// Checksum-invalid look-alikes embedded as distractors; the extractor must not report them.
    let invalidIdentifiers: [String]?

    /// Optional members are omitted when absent.
    var json: JSON {
        var members: [(String, JSON)] = [
            ("file", .string(file)), ("lang", .string(lang.rawValue)), ("kind", .string(kind.rawValue)),
            ("core", .bool(core)), ("expected", expected.json),
        ]
        if let acceptAlso { members.append(("accept_also", acceptAlso.json)) }
        if let duplicateOf { members.append(("duplicate_of", .string(duplicateOf))) }
        if let encoding { members.append(("encoding", .string(encoding.rawValue))) }
        if let password { members.append(("password", .string(password))) }
        if let invalidIdentifiers { members.append(("invalid_identifiers", .array(invalidIdentifiers.map { .string($0) }))) }
        return .object(members)
    }
}

struct Manifest: Decodable, Sendable {
    let schema: Int
    let baselineVersion: Int
    /// Seed the corpus was generated with (used by `--verify` to re-render and compare bytes).
    let seed: UInt64
    let fixtures: [FixtureRecord]

    static let currentSchema = 1
    static let baselineVersion = 1
    static let fileName = "expected.json"

    /// UTF-8 JSON with a trailing newline.
    var data: Data {
        let document = JSON.object([
            ("schema", .integer(UInt64(schema))),
            ("baseline_version", .integer(UInt64(baselineVersion))),
            ("seed", .integer(seed)),
            ("fixtures", .array(fixtures.map(\.json))),
        ])
        return Data((document.rendered() + "\n").utf8)
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// What to render for a fixture.
enum Payload: Sendable {
    case pdfText(Document)
    case pdfScan(ScanSource)
    case docx(Document)
    case xlsx(Workbook)
    case screenshot(Screenshot)
    case photo(Photo)
    case email(Email)
    case text(String, TextEncoding)
    /// Byte-identical copy of an earlier fixture.
    case copy(of: String)
    case encryptedPDF(Document, password: String)
    case truncatedPDF(Document)
}

enum ScanSource: Sendable {
    /// A paginated document printed and scanned.
    case document(Document)
    /// An ID page lying on the scanner glass.
    case card(Card, info: DocumentInfo)
    /// An empty sheet.
    case blank(DocumentInfo)
}

struct Fixture: Sendable {
    let record: FixtureRecord
    let payload: Payload

    /// Printed text of fixtures that are only readable through OCR (nil for the others, whose text layer
    /// `--verify` inspects directly).
    var ocrSourceText: String? {
        switch payload {
        case .pdfScan(.document(let document)): document.plainText
        case .pdfScan(.card(let card, _)): card.plainText
        case .photo(let photo):
            switch photo.subject {
            case .receipt(let receipt): receipt.plainText
            case .card(let card): card.plainText
            }
        case .screenshot(let screen): ([screen.amount, screen.counterparty, screen.footnote] + screen.rows.map(\.value)).joined(separator: "\n")
        default: nil
        }
    }

    /// Encryption salts the file with random data, so only this payload escapes byte-for-byte determinism.
    var isByteDeterministic: Bool {
        if case .encryptedPDF = payload { return false }
        return true
    }

    /// A document the app should file under `category` and rename.
    static func filed(
        _ file: String, _ lang: Language, _ kind: FixtureKind, core: Bool,
        category: String, year: Int?, type: DocType, correspondent: String, date: Day, title: String,
        titleContains: [String], identifiers: [Identifier] = [], minBand: Band = .check,
        acceptAlso: AcceptAlso? = nil, invalidIdentifiers: [Identifier] = [], warnings: [WarningCode] = [],
        encoding: TextEncoding? = nil, payload: Payload
    ) -> Fixture {
        precondition(identifiers.allSatisfy(\.isChecksumValid), "\(file): an expected identifier fails its checksum")
        precondition(!invalidIdentifiers.contains(where: \.isChecksumValid), "\(file): a distractor passes its checksum")
        let fileExtension = (file as NSString).pathExtension.lowercased()
        let expected = Expected(
            category: category, yearFolder: year.map(String.init), docType: type, correspondent: correspondent,
            date: date.iso, titleContains: titleContains, identifiers: identifiers.map(\.token),
            renamed: "\(date.iso) \(correspondent) - \(type.label) - \(title).\(fileExtension)",
            minBand: minBand, warnings: warnings.isEmpty ? nil : warnings)
        let record = FixtureRecord(
            file: file, lang: lang, kind: kind, core: core, expected: expected, acceptAlso: acceptAlso,
            duplicateOf: nil, encoding: encoding, password: nil,
            invalidIdentifiers: invalidIdentifiers.isEmpty ? nil : invalidIdentifiers.map(\.token))
        return Fixture(record: record, payload: payload)
    }

    /// A file the app must hold back (Needs review or Duplicates) and leave unrenamed.
    static func heldBack(
        _ file: String, _ lang: Language, _ kind: FixtureKind, category: String, type: DocType?,
        titleContains: [String] = [], warnings: [WarningCode] = [], duplicateOf: String? = nil,
        password: String? = nil, payload: Payload
    ) -> Fixture {
        let expected = Expected(
            category: category, yearFolder: nil, docType: type, correspondent: nil, date: nil,
            titleContains: titleContains, identifiers: [], renamed: nil, minBand: .review,
            warnings: warnings.isEmpty ? nil : warnings)
        let record = FixtureRecord(
            file: file, lang: lang, kind: kind, core: true, expected: expected, acceptAlso: nil,
            duplicateOf: duplicateOf, encoding: nil, password: password, invalidIdentifiers: nil)
        return Fixture(record: record, payload: payload)
    }
}
