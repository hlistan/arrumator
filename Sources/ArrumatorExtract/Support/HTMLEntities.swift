import Foundation

/// Why data bundled with the module cannot be used: the build left it out, or it was changed by hand.
enum BundledDataError: Error, LocalizedError, Equatable {
    case missing(String)
    case malformed(name: String, line: Int)

    var errorDescription: String? {
        switch self {
        case let .missing(name): "\(name) is missing from the bundle"
        case let .malformed(name, line): "\(name) in the bundle is malformed at line \(line)"
        }
    }
}

/// The named character references of HTML (`&ccedil;` for `ç`): every one the HTML Standard lists with its `;`, from
/// the WHATWG's table (https://html.spec.whatwg.org/entities.json, the standard's section 13.5, "Named character
/// references"). The table is bundled as `Entities/html-entities.txt`, a line for each reference: its name without
/// `&` and `;`, then the code points it stands for in hexadecimal. Names are case-sensitive (`&Ccedil;` is `Ç`).
struct HTMLEntities: Sendable {
    private let characters: [String: String]

    /// The bundled table, read once by the registry that hands it to the extractors.
    static func bundled() throws -> HTMLEntities {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension,
                                          subdirectory: resourceFolder) else {
            throw BundledDataError.missing("\(resourceName).\(resourceExtension)")
        }
        return try HTMLEntities(table: String(contentsOf: url, encoding: .utf8),
                                name: "\(resourceName).\(resourceExtension)")
    }

    /// Reads `table`, whose lines are a name and its hexadecimal code points; a line starting with `#` is a comment.
    init(table: String, name: String) throws {
        var characters: [String: String] = [:]
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty && !line.hasPrefix(Self.comment) {
            let fields = line.split(separator: " ")
            let scalars = fields.dropFirst().compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
            guard let reference = fields.first, !scalars.isEmpty, scalars.count == fields.count - 1 else {
                throw BundledDataError.malformed(name: name, line: index + 1)
            }
            characters[String(reference)] = String(String.UnicodeScalarView(scalars))
        }
        self.characters = characters
    }

    /// What the reference `&name;` stands for, or `nil` when HTML has no such name.
    func character(named name: String) -> String? { characters[name] }

    private static let resourceName = "html-entities"
    private static let resourceExtension = "txt"
    private static let resourceFolder = "Entities"
    private static let comment = "#"
}
