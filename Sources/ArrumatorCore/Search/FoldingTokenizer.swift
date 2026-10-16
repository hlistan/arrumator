import Foundation
import GRDB

/// The full-text index's tokenizer: words as `unicode61` finds them, with a combining mark kept inside its word (a
/// decomposed `ç` is one letter, not a separator), each folded to one spelling, so a search ignores case and accents in
/// every script and finds a decomposed (NFD) text or query as a composed (NFC) one. `unicode61` alone removes diacritics
/// of Latin script only: it leaves Cyrillic `ё` and Greek `ά` as they are.
///
/// Folding is what Foundation calls case and diacritic insensitive comparison, in the composed form. It makes `й` match
/// `и`, which the search accepts for the recall. What is indexed is only this fold: the text a document keeps
/// (`document_text.body`) is never changed.
///
/// A connection registers it before it reads or writes the index (`AppDatabase.register(_:)`), as plain `sqlite3` cannot
/// query the index.
final class FoldingTokenizer: FTS5WrapperTokenizer {
    static let name = "folding"

    /// The categories whose characters make words: letters, numbers, private use (as `unicode61` has them) and marks.
    static let categories = "L* N* Co M*"

    let wrappedTokenizer: any FTS5Tokenizer

    init(db: Database, arguments: [String]) throws {
        wrappedTokenizer = try db.makeTokenizer(.unicode61(diacritics: .keep, categories: Self.categories))
    }

    func accept(token: String, flags: FTS5TokenFlags, for tokenization: FTS5Tokenization,
                tokenCallback: FTS5WrapperTokenCallback) throws {
        try tokenCallback(Self.folded(token), flags)
    }

    /// `text` without case or accents, in the composed form.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    static var descriptor: FTS5TokenizerDescriptor { tokenizerDescriptor() }
}
