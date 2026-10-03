import ArrumatorCore
import Foundation
import Testing

/// An answer is written in Markdown (conversation-system.md): its paragraphs, headings, lists and code are shown as such,
/// not as the characters that mark them.
@Suite struct AnswerMarkdownTests {
    static let draft = """
        ### Resumo

        As faturas somam **72,61 EUR**:

        - EDP: 54,21 EUR
        - Águas:
          - março: 10,00 EUR
          - maio: 8,40 EUR

        1. Pagar
        2. Arquivar

        > Nota do contrato

        ```
        U-2653
        ```
        """

    @Test func anAnswerIsShownBlockByBlock() throws {
        let blocks = try #require(AnswerMarkdown.blocks(Self.draft))
        let shown = blocks.map { (String($0.text.characters), $0.kind, $0.depth) }
        #expect(shown.map(\.0) == ["Resumo", "As faturas somam 72,61 EUR:", "EDP: 54,21 EUR", "Águas:", "março: 10,00 EUR",
                                   "maio: 8,40 EUR", "Pagar", "Arquivar", "Nota do contrato", "U-2653"],
                "each block holds its words, without the marks that made it one")
        #expect(shown.map(\.1) == [.heading(3), .paragraph, .item(marker: "•"), .item(marker: "•"), .item(marker: "•"), .item(marker: "•"),
                                   .item(marker: "1."), .item(marker: "2."), .quote, .code],
                "a heading, a paragraph, list items with their markers, a quote and code")
        #expect(shown.map(\.2) == [0, 0, 0, 0, 1, 1, 0, 0, 0, 0], "an item of a list within a list sits deeper")
        let bold = blocks[1].text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(blocks[1].text[$0.range].characters) } == "72,61 EUR", "and the emphasis within a block is kept")
    }

    /// An answer is untrusted: a document can ask the model to end it with a link that carries the document's data to a
    /// host of its choosing. Nothing in it becomes clickable; a link shows as its words and, when they differ, its
    /// address as plain text, so nothing is hidden either; an image shows as its words.
    @Test func linksAndImagesInAnAnswerBecomeTheirWordsAndNothingIsActive() throws {
        let answer = """
            Veja [os detalhes](https://x.example/?d=PT50000201231234567890154) e **[a fatura](https://x.example/f)**.

            Fonte: <https://x.example/fonte>

            ![logótipo da EDP](https://x.example/logo.png)
            """
        let blocks = try #require(AnswerMarkdown.blocks(answer))
        #expect(blocks.map { String($0.text.characters) } == [
            "Veja os detalhes (https://x.example/?d=PT50000201231234567890154) e a fatura (https://x.example/f).",
            "Fonte: https://x.example/fonte",
            "logótipo da EDP",
        ], "a link shows its words and its address, an autolink its address once, an image its words")
        for block in blocks {
            #expect(block.text.runs.allSatisfy { $0.link == nil && $0.imageURL == nil },
                    "nothing in “\(String(block.text.characters))” opens anything when clicked")
        }
        let bold = blocks[0].text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(blocks[0].text[$0.range].characters) }
        #expect(bold.joined() == "a fatura (https://x.example/f)", "a link keeps the emphasis it had, its address with it")
    }

    @Test func aTableIsShownAsItsRowsAlignedNotACellPerParagraph() throws {
        let answer = """
            As faturas:

            | Emissor | Total |
            |---|---:|
            | EDP | **54,21 EUR** |
            | [Águas](https://x.example/a) | 8,40 EUR |

            Fim.
            """
        let blocks = try #require(AnswerMarkdown.blocks(answer))
        #expect(blocks.map(\.kind) == [.paragraph, .code, .paragraph], "the table is one block between the paragraphs, shown as code is")
        #expect(String(blocks[1].text.characters) == """
            Emissor                      Total
            ---------------------------  ---------
            EDP                          54,21 EUR
            Águas (https://x.example/a)  8,40 EUR
            """, "each row on a line, its columns aligned, the heading ruled off, a link its words and address")
        #expect(blocks[1].text.runs.allSatisfy { $0.link == nil && $0.imageURL == nil }, "and nothing in it opens anything")
    }

    @Test func plainTextIsOneParagraphAndUnfinishedMarkdownStillShows() throws {
        #expect(try #require(AnswerMarkdown.blocks("Duas faturas.")).map(\.kind) == [.paragraph])
        let partial = try #require(AnswerMarkdown.blocks("- EDP: **54,2"), "an answer still being written is shown as far as it came")
        #expect(partial.map(\.kind) == [.item(marker: "•")] && String(partial[0].text.characters).hasPrefix("EDP: "))
    }
}
