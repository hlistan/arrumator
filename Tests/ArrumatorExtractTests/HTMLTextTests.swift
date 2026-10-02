@testable import ArrumatorExtract
import Foundation
import Testing

@Suite("HTML to text")
struct HTMLTextTests {
    @Test("Well-formed HTML: hidden parts removed, block ends become lines and cell ends tabs, other tags dropped",
          arguments: [
              ("<p>Hello &amp; welcome</p><p>Line&nbsp;two</p>", "Hello & welcome\nLine\u{00A0}two\n",
               "paragraphs end in a line break, and references are decoded after the tags are gone"),
              (#"<head><title>T</title><style>p{color:red}</style></head><body><script type="x">var a = '<b>';</script>Text</body>"#,
               "Text", "the head, style sheets and scripts are removed with everything in them"),
              ("a<!-- hidden <b>x</b> -->b", "ab", "a comment is removed with what it holds"),
              ("one<br/>two<BR >three</DIV>four</Blockquote>five", "one\ntwo\nthree\nfour\nfive",
               "a line break and the end of a block end a line, whatever their case"),
              ("<table><tr><th>Item</th><th>Valor</th></tr><tr><td>Luz</td><td>45,90</td></tr></table>",
               "Item\tValor\nLuz\t45,90\n\n", "a cell ends in a tab and a row in a line, with no tab before it"),
              ("<p>a   </p>\n\n\n\n<p>b</p>", "a\n\nb\n", "spaces before a line break go, and blank lines collapse to one"),
              ("<p>Счёт №5 — 15 мая</p>", "Счёт №5 — 15 мая\n", "text in any script is kept as written"),
              ("<header>Top</header><pre>x</pre>y", "Topxy",
               "an element whose name only begins like a removed or block one is an ordinary tag"),
              ("<thead><tr><th>A</th></tr></thead>", "A\n", "the end of a table head is no line of its own"),
              ("a <> b", "a <> b", "angle brackets with nothing between them are text"),
          ])
    func wellFormed(html: String, text: String, why: String) throws {
        #expect(HTMLText.strip(html, entities: try HTMLEntities.bundled()) == text, "\(why)")
    }

    @Test("Every named character reference of HTML is decoded, and numeric ones; an unknown name stays as written",
          arguments: [
              ("Informa&ccedil;&atilde;o sobre a fatura n&ordm; 5", "Informação sobre a fatura nº 5",
               "Portuguese accents written as references are letters again"),
              ("&Ccedil;&Eacute;&Uuml; &ccedil;&eacute;&uuml;", "ÇÉÜ çéü", "a capital letter's name is its own"),
              ("Счёт &#1052;&#x438;&#X440;", "Счёт Мир", "decimal and hexadecimal references are any character"),
              ("&NotEqualTilde; &frac12;", "\u{2242}\u{0338} ½", "a name can stand for two code points, and hold digits"),
              ("&notaname; &amp &#xZZ;", "&notaname; &amp &#xZZ;",
               "a name HTML does not have, one without its semicolon and a malformed number stay as written"),
          ])
    func references(html: String, text: String, why: String) throws {
        #expect(Array(HTMLText.strip(html, entities: try HTMLEntities.bundled()).utf8) == Array(text.utf8), "\(why)")
    }

    @Test("A table of references with a line that is not a name and its code points is refused, naming the line")
    func malformedTable() {
        #expect(throws: BundledDataError.malformed(name: "table", line: 3), "a damaged bundle stops the registry, saying where") {
            try HTMLEntities(table: "# a comment\namp 26\namp\n", name: "table")
        }
        #expect(throws: BundledDataError.malformed(name: "table", line: 1), "a code point that is not hexadecimal is damage too") {
            try HTMLEntities(table: "amp 2G\n", name: "table")
        }
    }

    /// What a hostile e-mail leaves open, filling the whole body an e-mail is read with.
    enum Unclosed: String, CaseIterable, Sendable {
        case style, comment, tag

        func html(bytes: Int) -> String {
            switch self {
            case .style: "<style>" + String(repeating: "a", count: bytes - "<style>".utf8.count)
            case .comment: "<!--" + String(repeating: "a", count: bytes - "<!--".utf8.count)
            case .tag: String(repeating: "<a ", count: bytes / "<a ".utf8.count)
            }
        }

        /// What is left: a tag without its end is text, and a style sheet without its end is not removed, as before.
        func text(of html: String) -> String {
            self == .style ? String(html.dropFirst("<style>".count)) : html
        }
    }

    // Each search for what closes a construct used to start again at every later position: 32 KB of unclosed `<`
    // took 6 s, four times as long for each doubling, so the cap took hours.
    @Test("An unclosed style sheet, comment or tag the size of the largest e-mail body is read in one pass",
          .timeLimit(.minutes(1)), arguments: Unclosed.allCases)
    func unclosed(_ construct: Unclosed) throws {
        let html = construct.html(bytes: try TestConfig.pipeline().extraction.emailBodyCapBytes)
        #expect(HTMLText.strip(html, entities: try HTMLEntities.bundled()) == construct.text(of: html),
                "an unclosed \(construct.rawValue) is kept as text, and finding that it is unclosed takes one pass")
    }
}
