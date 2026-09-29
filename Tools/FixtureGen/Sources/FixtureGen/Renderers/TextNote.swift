import Foundation

enum TextNoteError: Error, CustomStringConvertible {
    case unencodable(TextEncoding)

    var description: String {
        switch self {
        case .unencodable(let encoding): "text contains characters that \(encoding.rawValue) cannot represent"
        }
    }
}

/// Plain-text document in a legacy or modern encoding (no byte-order mark).
struct TextNoteRenderer {
    func render(_ text: String, encoding: TextEncoding) throws -> Data {
        guard let data = text.data(using: encoding.stringEncoding, allowLossyConversion: false) else {
            throw TextNoteError.unencodable(encoding)
        }
        return data
    }
}
