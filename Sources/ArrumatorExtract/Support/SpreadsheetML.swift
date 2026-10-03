import ArrumatorCore
import Foundation

/// Why a workbook's structure cannot be read.
enum SpreadsheetError: Error, CustomStringConvertible {
    case noWorkbook
    case malformed(part: String)

    var description: String {
        switch self {
        case .noWorkbook: "the package names no workbook"
        case let .malformed(part): "\(part) is not well-formed XML"
        }
    }
}

/// What an Office Open XML spreadsheet package holds: its first sheets in the workbook's order and where each is, how
/// many it has, and where the shared strings are (ECMA-376 Part 1, §18.2; Part 2, §9 for relationships).
struct SpreadsheetPackage {
    struct Sheet {
        let name: String
        let path: String
    }

    /// The workbook's first `maxSheets` worksheets, in its order.
    let sheets: [Sheet]
    /// How many worksheets the workbook has, those past `maxSheets` included.
    let sheetCount: Int
    let sharedStringsPath: String

    /// The name Excel gives the shared string table, beside the workbook (ECMA-376 Part 1 §12.3.15).
    static let conventionalSharedStrings = "sharedStrings.xml"

    /// Reads the workbook once: the main part a package has one of, which the first relationship of the main part's
    /// type names (ECMA-376 Part 2 §9.2, Part 1 §11.3.10); another relationship to it, or to another, is not followed.
    init(_ zip: ZipReader, maxSheets: Int) throws {
        guard let workbook = try Relationships.read(zip, of: "")
            .first(where: { $0.type.hasSuffix(Relationships.officeDocument) }) else { throw SpreadsheetError.noWorkbook }
        let relationships = try Relationships.read(zip, of: workbook.target)
        let worksheets = Dictionary(relationships.filter { $0.type.hasSuffix(Relationships.worksheet) }
            .map { ($0.id, $0.target) }, uniquingKeysWith: { first, _ in first })
        guard let data = try zip.data(at: workbook.target) else { throw SpreadsheetError.noWorkbook }
        let collector = WorkbookCollector(worksheets: worksheets, maxSheets: maxSheets)
        guard collector.parse(data) else { throw SpreadsheetError.malformed(part: workbook.target) }
        try Task.checkCancellation()
        sheets = collector.sheets
        sheetCount = collector.count
        // The table the workbook's relationship names; without one, the part where Excel puts it, beside the
        // workbook, which CoreXLSX read whatever the relationships said.
        sharedStringsPath = relationships.first { $0.type.hasSuffix(Relationships.sharedStrings) }?.target
            ?? PartPath.join(PartPath.folder(of: workbook.target), Self.conventionalSharedStrings)
    }
}

/// The relationships of a part (ECMA-376 Part 2, §9.3): kept in `_rels/<name>.rels` beside it, each with an id, a
/// type and a target resolved against the part's folder; targets outside the package are left out.
enum Relationships {
    struct Relationship {
        let id: String
        let type: String
        let target: String
    }

    /// Relationship types, by how they end: the transitional and the strict namespace both end so.
    static let officeDocument = "/officeDocument"
    static let worksheet = "/worksheet"
    static let sharedStrings = "/sharedStrings"

    /// The relationships of the part at `source`, the package's own when it is empty; none when it has no file of them.
    static func read(_ zip: ZipReader, of source: String) throws -> [Relationship] {
        let folder = PartPath.folder(of: source)
        let file = PartPath.name(of: source)
        guard let data = try zip.data(at: PartPath.join(folder, "_rels/\(file).rels")) else { return [] }
        let collector = RelationshipCollector()
        guard collector.parse(data) else { throw SpreadsheetError.malformed(part: "the relationships of \(source)") }
        try Task.checkCancellation()
        return collector.relationships.compactMap { attributes in
            guard let id = attributes["Id"], let type = attributes["Type"], let target = attributes["Target"],
                  attributes["TargetMode"] != external else { return nil }
            return Relationship(id: id, type: type, target: PartPath.resolve(target, from: folder))
        }
    }

    private static let external = "External"
}

/// Part names inside a package: `/`-separated, resolved as relative references are (RFC 3986 §5.2).
enum PartPath {
    static func folder(of part: String) -> String {
        part.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
    }

    static func name(of part: String) -> String {
        part.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// `target` resolved against `folder`: from the package's root when it starts with `/`, with `.` and `..` removed.
    static func resolve(_ target: String, from folder: String) -> String {
        let base = target.hasPrefix("/") ? [] : folder.split(separator: "/").map(String.init)
        var segments = base
        for segment in target.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": _ = segments.popLast()
            default: segments.append(String(segment))
            }
        }
        return segments.joined(separator: "/")
    }
}

/// An `XMLParser` delegate that resolves no external entity and can be told to stop.
class PartCollector: NSObject, XMLParserDelegate {
    /// Parses `data`; whether it was well-formed XML to its end, or stopped on purpose.
    @discardableResult
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        return parser.parse() || stopped
    }

    /// Set when the collector stopped the parser itself.
    private(set) var stopped = false

    func stop(_ parser: XMLParser) {
        stopped = true
        parser.abortParsing()
    }
}

private final class RelationshipCollector: PartCollector {
    private(set) var relationships: [[String: String]] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard !Task.isCancelled else {
            stop(parser)
            return
        }
        if elementName == "Relationship" { relationships.append(attributeDict) }
    }
}

/// The workbook's worksheets, from its `<sheet>` elements in order: the first `maxSheets` by name and part, the rest
/// counted.
private final class WorkbookCollector: PartCollector {
    /// The part of each worksheet relationship, by its id.
    private let worksheets: [String: String]
    private let maxSheets: Int
    private(set) var sheets: [SpreadsheetPackage.Sheet] = []
    /// The worksheets found, past `maxSheets` too.
    private(set) var count = 0
    /// The `<sheet>` elements found, of whatever kind: what a sheet without a name is called by.
    private var elements = 0

    init(worksheets: [String: String], maxSheets: Int) {
        self.worksheets = worksheets
        self.maxSheets = maxSheets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard !Task.isCancelled else {
            stop(parser)
            return
        }
        guard elementName == "sheet" else { return }
        elements += 1
        // `r:id`, under whatever prefix the workbook gives the relationships namespace.
        guard let path = attributeDict.first(where: { $0.key.hasSuffix(":id") }).flatMap({ worksheets[$0.value] })
        else { return }
        count += 1
        if sheets.count < maxSheets {
            sheets.append(SpreadsheetPackage.Sheet(name: attributeDict["name"] ?? "Sheet \(elements)", path: path))
        }
    }
}

/// The text of a string's rich and plain runs (`<t>`), leaving out its phonetic runs (`<rPh>`), which are not part of
/// its value.
struct RunText {
    private var inRun = false
    private var inPhonetic = false
    private(set) var text = ""

    /// Starts a new string.
    mutating func reset() { text = "" }

    /// Follows the start of `element`; whether it was a run or a phonetic run.
    mutating func start(_ element: String) -> Bool {
        switch element {
        case "t": inRun = true
        case "rPh": inPhonetic = true
        default: return false
        }
        return true
    }

    /// Follows the end of `element`; whether it was a run or a phonetic run.
    mutating func end(_ element: String) -> Bool {
        switch element {
        case "t": inRun = false
        case "rPh": inPhonetic = false
        default: return false
        }
        return true
    }

    mutating func found(_ characters: String) {
        if inRun, !inPhonetic { text += characters }
    }
}

/// The shared string table (§18.4.9): one string per `<si>`, its runs joined.
final class SharedStringsCollector: PartCollector {
    private var runs = RunText()
    private(set) var strings: [String] = []

    /// The strings of the table in `data`, up to where it ends or is cut.
    static func strings(_ data: Data) throws -> [String] {
        let collector = SharedStringsCollector()
        collector.parse(data)
        try Task.checkCancellation()
        return collector.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard !runs.start(elementName), elementName == "si" else { return }
        runs.reset()
        if Task.isCancelled { stop(parser) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { runs.found(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        runs.found(String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if !runs.end(elementName), elementName == "si" { strings.append(runs.text) }
    }
}

/// A worksheet's rows (§18.3.1.73) as they are parsed: each `<row>`'s cells by column, stopping at the row after the
/// last one wanted.
final class WorksheetCollector: PartCollector {
    struct Rows {
        /// The non-empty rows among the first `maxRows`, each as many cells as its last column wanted.
        var rows: [[String]]
        /// Whether the sheet has rows after the first `maxRows`.
        var moreRows: Bool
        /// Whether the XML was well-formed as far as it was read.
        var wellFormed: Bool
    }

    private let sharedStrings: [String]
    private let limits: ExtractionConfig.XLSX
    private var runs = RunText()
    private var rows: [[String]] = []
    private var rowCount = 0
    private var moreRows = false
    private var cells: [String] = []
    private var column = -1
    private var cellType: String?
    private var value: String?
    private var inValue = false
    private var inlineString: String?

    private init(sharedStrings: [String], limits: ExtractionConfig.XLSX) {
        self.sharedStrings = sharedStrings
        self.limits = limits
    }

    static func rows(_ data: Data, sharedStrings: [String], limits: ExtractionConfig.XLSX) throws -> Rows {
        let collector = WorksheetCollector(sharedStrings: sharedStrings, limits: limits)
        let wellFormed = collector.parse(data)
        try Task.checkCancellation()
        return Rows(rows: collector.rows, moreRows: collector.moreRows, wellFormed: wellFormed)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard !runs.start(elementName) else { return }
        switch elementName {
        case "row":
            rowCount += 1
            guard rowCount <= limits.maxRows, !Task.isCancelled else {
                moreRows = !Task.isCancelled
                stop(parser)
                return
            }
            cells = []
            column = -1
        case "c":
            // A cell without a reference follows the one before it; any column at or past the limit is left out, so
            // counting stops there.
            column = attributeDict["r"].flatMap { Self.column(of: $0, limit: limits.maxColumns) }
                ?? min(column + 1, limits.maxColumns)
            cellType = attributeDict["t"]
            value = nil
            inlineString = nil
        case "v":
            inValue = true
            value = ""
        case "is":
            runs.reset()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        runs.found(string)
        if inValue { value? += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard !runs.end(elementName) else { return }
        switch elementName {
        case "v":
            inValue = false
        case "is":
            inlineString = runs.text
        case "c":
            guard column >= 0, column < limits.maxColumns else { return }
            if cells.count <= column { cells += [String](repeating: "", count: column + 1 - cells.count) }
            cells[column] = text()
        case "row":
            if !cells.allSatisfy(\.isEmpty) { rows.append(cells) }
        default:
            break
        }
    }

    /// The cell's text: a shared string by its index, checked since it comes from the file; else its inline string;
    /// else its value as stored.
    private func text() -> String {
        if cellType == Self.sharedStringType {
            guard let index = value.flatMap({ Int($0) }), sharedStrings.indices.contains(index) else { return "" }
            return sharedStrings[index]
        }
        return inlineString ?? value ?? ""
    }

    /// The 0-based column of a cell reference such as `AB12`; `limit` or more when it lies at or past `limit`, without
    /// reading further; `nil` when the reference has no column letters.
    static func column(of reference: String, limit: Int) -> Int? {
        var number = 0
        for character in reference {
            guard let letter = columnLetters.firstIndex(of: character) else { break }
            let (shifted, overflowed) = number.multipliedReportingOverflow(by: columnLetters.count)
            let (next, overflowedAgain) = shifted.addingReportingOverflow(letter + 1)
            guard !overflowed, !overflowedAgain, next <= limit else { return limit }
            number = next
        }
        return number == 0 ? nil : number - 1
    }

    private static let columnLetters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let sharedStringType = "s"
}
