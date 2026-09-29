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
        #expect(name == "2026-07-31 Сбербанк - Выписка по счёту- июль.pdf")
    }

    @Test func withoutAModelNameTheDocumentKeepsItsOwn() {
        #expect(builder.name(for: decision(named: nil), source: source, transliterate: false) == "scan_0001.pdf")
        #expect(builder.name(for: decision(named: "  "), source: source, transliterate: false) == "scan_0001.pdf")
    }

    @Test func transliterationIsOptIn() {
        let name = builder.name(for: decision(named: "2026-01-01 Сбербанк - Выписка"), source: source, transliterate: true)
        #expect(name.allSatisfy { $0.isASCII })
    }

    @Test func modelNamesAreSanitisedAndBounded() throws {
        let config = try PipelineConfig.bundledDefaults().naming
        #expect(builder.bounded("2026-07-05 EDP / Fatura: julho", fileExtension: "PDF") == "2026-07-05 EDP - Fatura- julho.pdf")
        #expect(builder.bounded("name.pdf", fileExtension: "pdf") == "name.pdf")
        let long = builder.bounded(String(repeating: "Выписка ", count: 60), fileExtension: "pdf")
        #expect(long.count <= config.maxChars && long.utf8.count <= config.maxBytes && long.hasSuffix(".pdf"))
    }
}
