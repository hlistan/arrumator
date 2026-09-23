import ArrumatorCore
import Foundation
import Testing

@Suite struct AboutFileTests {
    func sample() -> AboutFile {
        AboutFile(definition: FolderDefinition(code: "32", area: "30-39", name: "Utilities",
                                               description: "Electricity, gas and water invoices; квитанции ЖКХ.",
                                               yearSubfolders: true, yearRule: .documentDate, autoFile: true, origin: .learned),
                  body: "# 32 Utilities\n\n## What belongs here\nBills.")
    }

    @Test func roundTripAndPristine() throws {
        let text = try sample().render(hash: .recompute)
        let parsed = try AboutFile.parse(text, path: "t")
        #expect(parsed.definition.code == "32")
        #expect(parsed.definition.description.contains("квитанции"))
        #expect(parsed.definition.yearRule == .documentDate)
        #expect(parsed.body.hasPrefix("# 32 Utilities"))
        #expect(parsed.isPristine)
    }

    @Test func userEditIsDetectedAndLearnedBlockSurvives() throws {
        var about = try AboutFile.parse(try sample().render(hash: .recompute), path: "t")
        about.body += "\nMy own note."
        #expect(!about.isPristine)
        about.learned = LearnedBlock(examples: ["2026-09-01 DIGI - Fatura.pdf", "2026-08-01 DIGI - Fatura.pdf"],
                                     correspondents: ["DIGI"], updated: "2026-09-10")
        let rewritten = try about.render(hash: .preserve)
        let again = try AboutFile.parse(rewritten, path: "t")
        #expect(!again.isPristine)
        #expect(again.learned.examples == ["2026-09-01 DIGI - Fatura.pdf", "2026-08-01 DIGI - Fatura.pdf"])
        #expect(again.learned.correspondents == ["DIGI"])
        #expect(again.body.contains("My own note."))
        #expect(!again.body.contains("arrumator:learned"))
    }

    @Test func missingFrontMatterThrows() {
        #expect(throws: FrontMatterError.self) { try AboutFile.parse("# Just markdown", path: "x") }
    }
}
