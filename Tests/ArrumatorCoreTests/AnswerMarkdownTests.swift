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

    @Test func plainTextKeepsTheWordsWithoutTheMarks() {
        #expect(AnswerMarkdown.plainText(Self.draft) == """
            Resumo

            As faturas somam 72,61 EUR:

            • EDP: 54,21 EUR
            • Águas:
              • março: 10,00 EUR
              • maio: 8,40 EUR

            1. Pagar
            2. Arquivar

            Nota do contrato

            U-2653
            """, "no #, **, -, > or fence: the words, the lists with their markers and nesting, the quote and the code as text")
    }

    @Test func aNumberedListWithinABulletedOneStaysInIt() {
        #expect(AnswerMarkdown.plainText("- A\n  1. x\n  2. y\n- B") == "• A\n  1. x\n  2. y\n• B",
                "a list within an item is part of it, and the next bullet goes on the first list")
    }

    @Test func plainTextKeepsCodeAsWritten() {
        #expect(AnswerMarkdown.plainText("Use `lista[7]` e\n\n```\nitens[42]\n  indentado\n```") == "Use lista[7] e\n\nitens[42]\n  indentado",
                "a span and a fence show the text as it is, indentation and brackets included")
    }

    @Test func aLinkInPlainTextIsItsWordsAndAddress() {
        #expect(AnswerMarkdown.plainText("Veja [os detalhes](https://x.example/d?x=1).") == "Veja os detalhes (https://x.example/d?x=1).",
                "a link is inert on the pasteboard as on screen: its words, then its address as text")
    }

    @Test func plainTextOfNonLatinText() {
        #expect(AnswerMarkdown.plainText("**Счёт** за *электроэнергию*\n\n- 請求書: 5 400 円") == "Счёт за электроэнергию\n\n• 請求書: 5 400 円",
                "the words of any script, without their marks")
    }

    @Test func plainTextOfNothingIsEmpty() {
        #expect(AnswerMarkdown.plainText("") == "", "nothing is nothing")
        #expect(AnswerMarkdown.plainText("   ").trimmingCharacters(in: .whitespaces).isEmpty, "and so is blank space")
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

    /// A model that opens emphasis and never closes it leaves the marks as text, which would show as asterisks
    /// (QA 2026-10-04, CNV-2): its words show without them, while code keeps every character it holds.
    @Test func emphasisNeverClosedShowsItsWordsWithoutTheMarks() throws {
        let answer = """
            - **Счёт за электроэнергию от Мосэнергосбыт, 1 234,56 RUB
            - **EDP**: 54,21 EUR, a nota * da fatura

            `2**10` e

            ```
            a ** b
            ```
            """
        let blocks = try #require(AnswerMarkdown.blocks(answer))
        #expect(blocks.map { String($0.text.characters) } == [
            "Счёт за электроэнергию от Мосэнергосбыт, 1 234,56 RUB", "EDP: 54,21 EUR, a nota * da fatura", "2**10 e", "a ** b",
        ], "unclosed marks go, closed ones make emphasis, a lone asterisk and code stay as written")
        let bold = blocks[1].text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(blocks[1].text[$0.range].characters) } == "EDP", "emphasis closed is still emphasis")
    }

    /// Only a mark that could have opened emphasis goes (CommonMark 0.31, 6.2: a left-flanking run, not also a closing
    /// one): asterisks a document's own figures carry, as a masked card or account number or a power, stay as written
    /// (review of 2026-10-04, finding 1).
    @Test func asterisksThatOpenNoEmphasisStayAsWritten() throws {
        let answer = """
            Cartão ****1234

            IBAN PT50 0035 **** **** 1234 5

            2**10 = 1024

            **Счёт за электроэнергию от Мосэнергосбыт (…):

            Total **

            ***Três faturas
            """
        let blocks = try #require(AnswerMarkdown.blocks(answer))
        #expect(blocks.map { String($0.text.characters) } == [
            "Cartão ****1234", "IBAN PT50 0035 **** **** 1234 5", "2**10 = 1024",
            "Счёт за электроэнергию от Мосэнергосбыт (…):", "Total **", "Três faturas",
        ], "a masked number, a run standing alone and one between digits keep their asterisks; an opener never closed loses its own")
    }

    /// A mask of two or three asterisks after a space, before a digit, is a document's own figure, not an opener: it
    /// stays, while an opener never closed before a word, at the start of its block or after a space, goes (second review
    /// of 2026-10-04, finding 3).
    @Test func aShortMaskBeforeADigitStaysAsWritten() throws {
        let answer = """
            Cartão ***1234

            NIF ***456789

            Conta **5678

            - **5678 é a conta

            Ver **Resumo das faturas
            """
        let blocks = try #require(AnswerMarkdown.blocks(answer))
        #expect(blocks.map { String($0.text.characters) } == [
            "Cartão ***1234", "NIF ***456789", "Conta **5678", "**5678 é a conta", "Ver Resumo das faturas",
        ], "masked figures keep their asterisks wherever they stand; an opener never closed before a word loses its own")
    }

    @Test func aRuleIsARuleWithNoTextOfItsOwn() throws {
        let blocks = try #require(AnswerMarkdown.blocks("Um\n\n---\n\nDois"))
        #expect(blocks.map(\.kind) == [.paragraph, .rule, .paragraph] && blocks[1].text.characters.isEmpty,
                "a thematic break is drawn as a rule, not written as a character")
    }

    @Test func plainTextIsOneParagraphAndUnfinishedMarkdownStillShows() throws {
        #expect(try #require(AnswerMarkdown.blocks("Duas faturas.")).map(\.kind) == [.paragraph])
        let partial = try #require(AnswerMarkdown.blocks("- EDP: **54,2"), "an answer still being written is shown as far as it came")
        #expect(partial.map(\.kind) == [.item(marker: "•")] && String(partial[0].text.characters).hasPrefix("EDP: "))
    }
}
