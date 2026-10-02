import ArrumatorCore
import Foundation
import Testing

@Suite struct FilenameBuilderTests {
    let builder: FilenameBuilder

    init() throws {
        builder = FilenameBuilder(config: try PipelineConfig.bundledDefaults().naming)
    }

    private func decision(named fileName: String?) -> DocumentAnalysis {
        DocumentAnalysis(fileName: fileName)
    }

    private let source = SourceFile(path: "/tmp/scan_0001.PDF", originalFilename: "scan_0001.PDF", fileExtension: "PDF",
                                    utType: "com.adobe.pdf", byteSize: 1, createdAt: nil, modifiedAt: nil, sha256: "x")

    @Test func theModelsNameIsUsedAndKeepsItsScript() {
        let name = builder.name(for: decision(named: "2026-07-31 Сбербанк - Выписка по счёту: июль"), source: source, transliterate: false)
        #expect(name == "2026-07-31 Сбербанк - Выписка по счёту - июль.pdf", "the name stays in the document's own script, with no colon")
    }

    @Test func withoutAModelNameTheDocumentKeepsItsOwn() {
        #expect(builder.name(for: decision(named: nil), source: source, transliterate: false) == "scan_0001.pdf", "no name from the model")
        #expect(builder.name(for: decision(named: "  "), source: source, transliterate: false) == "scan_0001.pdf", "a blank name is no name")
    }

    @Test func transliterationIsOptIn() {
        let name = builder.name(for: decision(named: "2026-01-01 Сбербанк - Выписка"), source: source, transliterate: true)
        #expect(name == "2026-01-01 Sberbank - Vypiska.pdf", "asked for, the name is written in Latin letters")
    }

    @Test func modelNamesAreSanitisedAndBounded() throws {
        let config = try PipelineConfig.bundledDefaults().naming
        #expect(builder.bounded("2026-07-05 EDP / Fatura: julho", fileExtension: "PDF") == "2026-07-05 EDP - Fatura - julho.pdf",
                "a slash or colon never reaches the file system, and the extension is lower case")
        #expect(builder.sanitize("Fatura No: TCSD65342868") == "Fatura No - TCSD65342868",
                "a colon between words becomes a dash between words, not one glued to the word before")
        #expect(builder.sanitize("Consulta 10:30 a/b") == "Consulta 10-30 a-b", "inside a word or a number, a plain dash")
        #expect(builder.bounded("name.pdf", fileExtension: "pdf") == "name.pdf", "a name that already ends in its extension does not get it twice")
        let long = builder.bounded(String(repeating: "Выписка ", count: 60), fileExtension: "pdf")
        #expect(long.count <= config.maxChars && long.utf8.count <= config.maxBytes && long.hasSuffix(".pdf"),
                "a long name is cut to what the file system allows, and keeps its extension")
    }

    @Test func aNameNeverLeavesItsDirectoryWhateverTheConfigurationForbids() throws {
        var naming = try PipelineConfig.bundledDefaults().naming
        naming.forbiddenCharacters = []
        let permissive = FilenameBuilder(config: naming)
        for written in ["../../Library/x", "/etc/passwd", "..", "a/../../b", "\u{0}evil"] {
            let name = permissive.name(for: decision(named: written), source: source, transliterate: false)
            #expect(!name.contains("/") && !name.contains("\u{0}") && name != "." && name != "..",
                    "\(written) became \(name): the model supplies a file name, never a path, whatever pipeline.json says")
        }
    }
}
