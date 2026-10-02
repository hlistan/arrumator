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

    @Test func plainTextIsOneParagraphAndUnfinishedMarkdownStillShows() throws {
        #expect(try #require(AnswerMarkdown.blocks("Duas faturas.")).map(\.kind) == [.paragraph])
        let partial = try #require(AnswerMarkdown.blocks("- EDP: **54,2"), "an answer still being written is shown as far as it came")
        #expect(partial.map(\.kind) == [.item(marker: "•")] && String(partial[0].text.characters).hasPrefix("EDP: "))
    }
}
