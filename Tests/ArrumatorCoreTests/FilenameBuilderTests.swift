@testable import ArrumatorCore
import Foundation
import Testing

@Suite struct FilenameBuilderTests {
    let builder: FilenameBuilder
    let skip: SkipRules

    init() throws {
        let config = try PipelineConfig.bundledDefaults()
        skip = SkipRules(watcher: config.watcher)
        builder = FilenameBuilder(config: config.naming, reserved: skip)
    }

    private func decision(named fileName: String?) -> DocumentAnalysis {
        DocumentAnalysis(fileName: fileName)
    }

    /// The name the document has: the one it arrived with, in Incoming.
    private let current = "scan_0001.PDF"

    @Test func theModelsNameIsUsedAndKeepsItsScript() {
        let name = builder.name(for: decision(named: "2026-07-31 Сбербанк - Выписка по счёту: июль"), current: current, transliterate: false)
        #expect(Array(name.utf8) == Array("2026-07-31 Сбербанк - Выписка по счёту - июль.pdf".precomposedStringWithCanonicalMapping.utf8),
                "the name stays in the document's own script, composed, with no colon")
        let decomposed = builder.name(for: decision(named: "Informac\u{0327}a\u{0303}o fiscal"), current: current, transliterate: false)
        #expect(Array(decomposed.utf8) == Array("Informa\u{00E7}\u{00E3}o fiscal.pdf".utf8),
                "a name the model writes decomposed, a letter then its accent, is written composed (NFC), byte for byte")
    }

    @Test func aReadingNamesADocumentByItsDateItsSenderAndItsTitleLeavingNoSeparatorForWhatItLacks() {
        #expect(builder.made(date: "2026-07-05", sender: "EDP", title: "Fatura julho") == "2026-07-05 EDP - Fatura julho", "all three")
        #expect(builder.made(date: "2025-08-20", sender: nil, title: "Contrat de location") == "2025-08-20 Contrat de location",
                "no sender leaves no dash after the date")
        #expect(builder.made(date: nil, sender: "EDP", title: "Fatura julho") == "EDP - Fatura julho", "no date leaves no space before")
        #expect(builder.made(date: nil, sender: nil, title: " - Nota sobre a caldeira - ") == "Nota sobre a caldeira",
                "the title alone, without separators at its ends")
        #expect(builder.made(date: "2026-07-05", sender: "EDP", title: "") == "2026-07-05 EDP", "no title leaves no dash after the sender")
        #expect(builder.made(date: "2026-07-05", sender: nil, title: "  ") == nil, "a date alone names nothing: the document keeps its own name")
        #expect(builder.made(date: "2026-07-05", sender: "EDP Comercial", title: "2026-07-05 edp comercial - Fatura")
                    == "2026-07-05 EDP Comercial - Fatura", "a title written as a whole name repeats neither its date nor its sender")
        #expect(builder.made(date: "2026-07-05", sender: "EDP", title: "EDP 2026-07-05 - Fatura") == "2026-07-05 EDP - Fatura",
                "in whichever order it writes them")
        #expect(builder.made(date: nil, sender: "EDP", title: "EDPR relatório") == "EDP - EDPR relatório",
                "a sender is taken off a title's start only as a whole word")
    }

    @Test func aReadingsNameFollowsThePartsAndSeparatorsTheConfigurationGives() throws {
        var naming = try PipelineConfig.bundledDefaults().naming
        naming.parts = [.sender, .title, .date]
        naming.separators = [" · ", " _ "]
        let ordered = FilenameBuilder(config: naming, reserved: skip)
        #expect(ordered.made(date: "2026-07-05", sender: "EDP", title: "Fatura julho") == "EDP · Fatura julho _ 2026-07-05",
                "each part in the configured order, each followed by its own separator")
        #expect(ordered.made(date: "2026-07-05", sender: nil, title: "_ Fatura julho ·") == "Fatura julho _ 2026-07-05",
                "a part the document lacks takes its separator with it, and a title loses the separators at its ends")
        #expect(ordered.made(date: "2026-07-05", sender: "EDP", title: "") == "EDP · 2026-07-05", "a separator follows a part only when one follows it")
        naming.parts = [.title]
        naming.separators = []
        #expect(FilenameBuilder(config: naming, reserved: skip).made(date: "2026-07-05", sender: "EDP", title: "EDP Fatura julho") == "Fatura julho",
                "a name of the title alone still leaves out the sender it begins with")
    }

    @Test func withoutAModelNameTheDocumentKeepsItsOwn() {
        #expect(builder.name(for: decision(named: nil), current: current, transliterate: false) == "scan_0001.pdf", "no name from the model")
        #expect(builder.name(for: decision(named: "  "), current: current, transliterate: false) == "scan_0001.pdf", "a blank name is no name")
        #expect(builder.name(for: decision(named: nil), current: "2026-07-05 EDP - Fatura (2).pdf", transliterate: false)
                    == "2026-07-05 EDP - Fatura (2).pdf",
                "a document in the archive keeps the name it has there, not the one it arrived with")
    }

    @Test(arguments: ["...", "///", " - ", ": : :", ". - ."])
    func aNameCleaningLeavesNothingOfIsNoName(_ written: String) {
        #expect(builder.name(for: decision(named: written), current: current, transliterate: false) == "scan_0001.pdf",
                "“\(written)” leaves no name once cleaned: the document keeps its own, not one made of its extension (pdf.pdf)")
        #expect(builder.name(for: decision(named: written), current: "README", transliterate: false) == "README",
                "nor an empty name, for a file without an extension")
        #expect(builder.name(for: decision(named: written), current: "-.pdf", transliterate: false) == "-.pdf",
                "and a document whose own name cleaning leaves nothing of keeps it as it is")
        #expect(builder.bounded(written, fileExtension: "pdf") == nil, "nothing that is a name is left of it")
    }

    @Test(arguments: [("_documents", "md", "a record file's name"), ("_Notes", "md", "the managed-file prefix on Markdown"),
                      ("~$Contract", "docx", "an Office lock file's prefix"), ("Thumbs", "db", "a name the watchers ignore"),
                      ("Report.sb-2a1", "pdf", "a name a sandboxed save leaves in progress")])
    func aNameTheAppKeepsForItsOwnFilesIsNeverGiven(_ written: String, _ fileExtension: String, _ why: String) {
        let current = "scan_0001." + fileExtension
        let name = builder.name(for: decision(named: written), current: current, transliterate: false)
        #expect(name == current, "\(written).\(fileExtension) is \(why): the document keeps its own name instead")
        #expect(skip.ignoreReason(name: name) == nil, "so a filed document is never mistaken for one of the app's files, or ignored")
        #expect(builder.bounded(written, fileExtension: fileExtension) == nil, "and a name typed by the user is refused the same way")
    }

    @Test func joinersAreKeptAndOtherInvisibleCharactersAreNot() {
        let persian = "نامه\u{200C}ها"
        let named = builder.name(for: decision(named: "2026-07-05 \(persian) 👩\u{200D}💻"), current: current, transliterate: false)
        #expect(Array(named.utf8) == Array("2026-07-05 \(persian) 👩\u{200D}💻.pdf".utf8),
                "the zero-width non-joiner of Persian and the joiner of an emoji are part of how the words are written, and stay")
        #expect(builder.sanitize("Fatura\u{202E}fdp.exe") == "Fatura fdp.exe",
                "a character that turns the direction of text, which could disguise a name, becomes a space")
    }

    @Test func transliterationIsOptIn() {
        let name = builder.name(for: decision(named: "2026-01-01 Сбербанк - Выписка"), current: current, transliterate: true)
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
        let long = try #require(builder.bounded(String(repeating: "Выписка ", count: 60), fileExtension: "pdf"))
        #expect(long.count <= config.maxChars && long.utf8.count <= config.maxBytes && long.hasSuffix(".pdf"),
                "a long name is cut to what the file system allows, and keeps its extension")
    }

    @Test func aNameNeverLeavesItsDirectoryWhateverTheConfigurationForbids() throws {
        let config = try PipelineConfig.bundledDefaults()
        var naming = config.naming
        naming.forbiddenCharacters = []
        let permissive = FilenameBuilder(config: naming, reserved: SkipRules(watcher: config.watcher))
        for written in ["../../Library/x", "/etc/passwd", "..", "a/../../b", "\u{0}evil"] {
            let name = permissive.name(for: decision(named: written), current: current, transliterate: false)
            #expect(!name.contains("/") && !name.contains("\u{0}") && name != "." && name != "..",
                    "\(written) became \(name): the model supplies a file name, never a path, whatever pipeline.json says")
        }
    }

    @Test func aNameTakenInADirectoryGetsTheCollisionSuffixAndAPathIsRefused() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let (free, none) = try builder.uniqueDestination(directory: env.root, filename: "bill.pdf")
        #expect(free.lastPathComponent == "bill.pdf" && none == nil, "a free name is used as it is")
        try Data("a bill".utf8).write(to: free)
        let (taken, n) = try builder.uniqueDestination(directory: env.root, filename: "bill.pdf")
        #expect(taken.lastPathComponent == "bill (2).pdf" && n == 2, "a taken one gets naming.collisionFormat before its extension")
        for path in ["../bill.pdf", "", "..", "a\u{0}b"] {
            #expect("“\(path)” is no name: nothing is placed outside the directory chosen") {
                try builder.uniqueDestination(directory: env.root, filename: path)
            } throws: { error in
                guard case .notAFileName(path)? = error as? FileOperationError else { return false }
                return true
            }
        }
    }

    @Test(arguments: [("Fatura (2).pdf", "Fatura.pdf", true, "the suffix a taken name was given"),
                      ("fatura.PDF", "Fatura.pdf", true, "another case"),
                      ("Fatura (13).pdf", "Fatura.pdf", true, "any suffix the directory needed"),
                      ("Fatura.pdf", "Fatura.pdf", true, "the same name"),
                      ("Fatura 2.pdf", "Fatura.pdf", false, "a number that is no collision suffix"),
                      ("Fatura (1).pdf", "Fatura.pdf", false, "a suffix the app never gives"),
                      ("Fatura (2).txt", "Fatura.pdf", false, "another extension"),
                      ("Recibo (2).pdf", "Fatura.pdf", false, "another name")])
    func aDocumentAlreadyNamedSoIsTheSameName(_ current: String, _ planned: String, _ same: Bool, _ why: String) {
        #expect(builder.isSameName(current, as: planned) == same,
                "\(current) against \(planned): \(why) \(same ? "is" : "is not") the name it already has")
    }
}
