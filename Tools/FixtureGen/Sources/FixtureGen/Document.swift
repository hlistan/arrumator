import CoreGraphics

/// An sRGB colour.
struct RGB: Sendable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    func cgColor(alpha: Double) -> CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    static let black = RGB(0, 0, 0)
    static let white = RGB(1, 1, 1)
    static let ink = RGB(0.11, 0.11, 0.13)
    static let muted = RGB(0.40, 0.41, 0.44)
    static let hairline = RGB(0.70, 0.71, 0.73)
}

enum FontFamily: Sendable {
    case sans, serif, mono
}

enum TextAlignment: Sendable {
    case left, right, center
}

/// Metadata written into the PDF Info dictionary / DOCX core properties.
struct DocumentInfo: Sendable {
    let title: String
    /// The issuing organisation, as a real generator would record it.
    let author: String
    let subject: String
    /// The document's issue date; used for the pinned creation date.
    let created: Day
}

struct Field: Sendable {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

struct Column: Sendable {
    let title: String
    /// Share of the text width.
    let width: Double
    let alignment: TextAlignment

    init(_ title: String, _ width: Double, _ alignment: TextAlignment = .left) {
        self.title = title
        self.width = width
        self.alignment = alignment
    }
}

struct Table: Sendable {
    let columns: [Column]
    let rows: [[String]]
    /// Bold rows below a rule (subtotals, totals).
    let totals: [[String]]

    init(_ columns: [Column], rows: [[String]], totals: [[String]] = []) {
        precondition(abs(columns.reduce(0) { $0 + $1.width } - 1) < 0.001, "column widths must add up to 1")
        precondition((rows + totals).allSatisfy { $0.count == columns.count }, "row width must match the columns")
        self.columns = columns
        self.rows = rows
        self.totals = totals
    }
}

/// Structural building blocks of a document. The same blocks render to a text-layer PDF, a scan or a DOCX.
enum Block: Sendable {
    /// Large coloured brand name with an optional legal-entity line underneath.
    case wordmark(String, tagline: String?)
    /// White text on an accent-coloured band.
    case banner(String)
    case title(String, alignment: TextAlignment = .left)
    case subtitle(String, alignment: TextAlignment = .left)
    case heading(String)
    case paragraph(String)
    case strong(String)
    case note(String)
    case fields([Field])
    case columns(left: [String], right: [String])
    case table(Table)
    case rule
    case gap
}

struct Document: Sendable {
    let info: DocumentInfo
    let family: FontFamily
    let accent: RGB
    /// Repeated at the bottom of every PDF page.
    let footer: String?
    /// Language of the "Page n of m" label; nil hides it.
    let pageNumbers: Language?
    let blocks: [Block]

    init(info: DocumentInfo, family: FontFamily = .sans, accent: RGB, footer: String? = nil,
         pageNumbers: Language? = nil, blocks: [Block]) {
        self.info = info
        self.family = family
        self.accent = accent
        self.footer = footer
        self.pageNumbers = pageNumbers
        self.blocks = blocks
    }
}

extension Language {
    func pageLabel(_ page: Int, of total: Int) -> String {
        switch self {
        case .pt: "Página \(page) de \(total)"
        case .ru: "Страница \(page) из \(total)"
        default: "Page \(page) of \(total)"
        }
    }
}

extension Document {
    /// The document's words without layout, for content checks.
    var plainText: String {
        blocks.map { block -> String in
            switch block {
            case .wordmark(let name, let tagline): ([name] + (tagline.map { [$0] } ?? [])).joined(separator: "\n")
            case .banner(let text), .title(let text, _), .subtitle(let text, _), .heading(let text), .paragraph(let text),
                 .strong(let text), .note(let text): text
            case .fields(let fields): fields.map { "\($0.label) \($0.value)" }.joined(separator: "\n")
            case .columns(let left, let right): (left + right).joined(separator: "\n")
            case .table(let table): ([table.columns.map(\.title)] + table.rows + table.totals).map { $0.joined(separator: " ") }.joined(separator: "\n")
            case .rule, .gap: ""
            }
        }.joined(separator: "\n") + (footer.map { "\n" + $0 } ?? "")
    }
}
