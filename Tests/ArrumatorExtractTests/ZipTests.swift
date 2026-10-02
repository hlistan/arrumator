import ArrumatorCore
@testable import ArrumatorExtract
import Foundation
import Testing

@Suite("ZIP files are checked against themselves before they are read")
struct ZipTests {
    private let registry: ExtractorRegistry

    init() throws { registry = try TestConfig.registry() }

    /// A file that lies about where its records are, or how large an entry is, in a way ZIPFoundation used to trap on:
    /// the process ended, and the job resumed into the same crash at the next start.
    enum Lie: String, CaseIterable, Sendable {
        /// A local header past `Int64.max`, where ZIPFoundation's `off_t(offset)` trapped.
        case offsetPastTheEnd
        /// A data descriptor after data whose size overflows the position ZIPFoundation computes for it.
        case descriptorPastTheEnd
        /// A ZIP64 record that puts the central directory past `Int64.max`.
        case directoryPastTheEnd
        /// Before a part that is read, a stored folder with a data descriptor and a ZIP64 size of 2^64 − 8. ZIPFoundation
        /// does not unpack a folder, but walking past it adds its size to where its data starts to find the descriptor
        /// (`Archive.swift:239`), which overflowed.
        case folderDescriptorOverflow
        /// Before a part that is read, a stored encrypted file with a data descriptor and a ZIP64 size of 2^63: the
        /// descriptor's place lies past `Int64.max`, where `off_t` trapped.
        case encryptedDescriptorPastInt64
        /// Before a part that is read, a stored file of no bytes with a data descriptor that declares a ZIP64 size of
        /// 2^63: what it declares makes it a file to unpack, whose data runs past the archive.
        case emptyFileDescriptorPastInt64

        var archive: ZipBuilder {
            var builder = ZipTests.package
            switch self {
            case .offsetPastTheEnd:
                builder.entries[1].zip64Offset = UInt64(Int64.max) + 1
            case .descriptorPastTheEnd:
                builder.entries[1].descriptor = .signed
                builder.entries[1].zip64Compressed = UInt64.max - 8
            case .directoryPastTheEnd:
                builder.zip64DirectoryOffset = UInt64(Int64.max) + 1
            case .folderDescriptorOverflow:
                builder.entries.insert(Self.notUnpacked(ZipBuilder.Entry(folder: "d/"), size: UInt64.max - 7), at: 1)
            case .encryptedDescriptorPastInt64:
                var sealed = ZipBuilder.Entry("d/sealed.bin", "x")
                sealed.encrypted = true
                builder.entries.insert(Self.notUnpacked(sealed, size: UInt64(Int64.max) + 1), at: 1)
            case .emptyFileDescriptorPastInt64:
                builder.entries.insert(Self.notUnpacked(ZipBuilder.Entry("d/empty.xml"), size: UInt64(Int64.max) + 1),
                                       at: 1)
            }
            return builder
        }

        /// `entry`, stored, with a data descriptor and a ZIP64 uncompressed size of `size`.
        private static func notUnpacked(_ entry: ZipBuilder.Entry, size: UInt64) -> ZipBuilder.Entry {
            var entry = entry
            entry.descriptor = .signed
            entry.zip64Uncompressed = size
            return entry
        }
    }

    /// The two parts the crafted files are made of.
    static let package = ZipBuilder(entries: [ZipBuilder.Entry("[Content_Types].xml", "<Types/>"),
                                              ZipBuilder.Entry("docProps/core.xml", "<coreProperties/>")])

    /// Two deflated entries whose declared sizes overflow when added, which `ArchiveExtractor`'s total trapped on.
    static var sizesThatOverflow: ZipBuilder {
        var builder = package
        for index in builder.entries.indices {
            builder.entries[index].method = 8
            builder.entries[index].zip64Uncompressed = UInt64.max / 2 + 1
        }
        return builder
    }

    @Test("A ZIP archive, workbook or deck that lies about where its records are or how large an entry is is refused as corrupted, and the process goes on",
          arguments: Lie.allCases, ["zip", "xlsx", "pptx"])
    func refused(_ lie: Lie, as fileExtension: String) async throws {
        let scratch = try Scratch()
        let url = try scratch.write("crafted.\(fileExtension)", data: lie.archive.data())
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.warnings.map(\.code) == [.corrupted], "\(lie): refused as corrupted (\(content.warningSummary))")
        #expect(content.text.isEmpty || content.textOrigin == .metadataOnly, "nothing is read from a file that lies")
    }

    @Test("A Word document that lies about where its records are or how large an entry is is read by textutil alone; its core properties are not looked for",
          arguments: Lie.allCases)
    func refusedDocx(_ lie: Lie) async throws {
        let scratch = try Scratch()
        let url = try scratch.write("crafted.docx", data: lie.archive.data())
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.metadata.keys.filter { $0.hasPrefix("doc:") }.isEmpty, "\(lie): no core property is read from it")
        #expect(content.extractorName == "textutil", "the process goes on, and textutil reports on the document itself")
    }

    @Test("Entries whose declared sizes overflow when added are listed without a total; no part of them is unpacked",
          arguments: ["zip", "xlsx", "pptx", "docx"])
    func sizesThatOverflow(as fileExtension: String) async throws {
        let scratch = try Scratch()
        let url = try scratch.write("crafted.\(fileExtension)", data: Self.sizesThatOverflow.data())
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.metadata.keys.filter { $0.hasPrefix("doc:") }.isEmpty,
                "\(fileExtension): a part that declares more than zipEntryCapBytes is not unpacked")
        let cap = try TestConfig.pipeline().extraction.zipEntryCapBytes
        let refused = ExtractionWarning(.tooLarge, ZipReadError.entryTooLarge(path: "docProps/core.xml", cap: cap).description)
        let noWorkbook = ExtractionWarning(.corrupted, SpreadsheetError.noWorkbook.description)
        let expected: [ExtractionWarning] = switch fileExtension {
        case "zip": []
        case "xlsx": [noWorkbook, refused, ExtractionWarning(.emptyText)]
        default: [refused, ExtractionWarning(.emptyText)]
        }
        #expect(content.warnings == expected,
                "\(fileExtension): the core properties are refused, and noted, for what they declare: \(content.warningSummary)")
        if fileExtension == "zip" {
            #expect(content.attachments == ["[Content_Types].xml", "docProps/core.xml"], "the entries are listed")
            #expect(content.metadata["archive:uncompressedBytes"] == nil, "sizes whose sum overflows give no total")
        }
    }

    /// What an honest package holds besides its parts: an empty file, and a folder of its own.
    static let honestFiles = ExcelWorkbook.files().merging(["xl/empty.xml": ""]) { $1 }
    static let honestFolders = ["xl/media"]

    @Test("A package whose entries end in data descriptors, in every form a writer may give them, reads in full",
          arguments: ZipBuilder.Descriptor.allCases)
    func descriptors(_ form: ZipBuilder.Descriptor) async throws {
        var entries = Self.honestFiles.sorted { $0.key < $1.key }.map { ZipBuilder.Entry($0.key, $0.value) }
        for index in entries.indices { entries[index].descriptor = form }
        entries += Self.honestFolders.map { ZipBuilder.Entry(folder: $0 + "/") }
        try await expectReadInFull(ZipBuilder(entries: entries).data(), "with descriptors of \(form.rawValue) bytes")
    }

    @Test("A package as each archiver on the Mac writes it, with a folder and an empty file, reads in full",
          arguments: Scratch.Archiver.allCases)
    func archivers(_ archiver: Scratch.Archiver) async throws {
        let url = try Scratch().writeArchive("package.zip", files: Self.honestFiles, folders: Self.honestFolders,
                                             with: archiver)
        try await expectReadInFull(try Data(contentsOf: url), "as \(archiver) writes it")
    }

    /// `package` read as a workbook and listed as an archive: every sheet read, every file listed with its size, and
    /// nothing refused.
    private func expectReadInFull(_ package: Data, _ written: String) async throws {
        let scratch = try Scratch()
        let context = try TestConfig.context()
        let workbook = try await registry.extract(try scratch.write("package.xlsx", data: package), sha256: "x",
                                                  context: context, trace: .disabled)
        #expect(workbook.text == ExcelWorkbook.text, "\(written): every sheet is read (\(workbook.warningSummary))")
        #expect(workbook.warnings.isEmpty, "\(written): \(workbook.warningSummary)")
        let archive = try await registry.extract(try scratch.write("package.zip", data: package), sha256: "x",
                                                 context: context, trace: .disabled)
        #expect(Set(archive.attachments) == Set(Self.honestFiles.keys), "\(written): every file is listed, and only files")
        #expect(archive.text.contains("xl/empty.xml\t0"), "\(written): the empty file is listed as empty")
        #expect(archive.warnings.isEmpty, "\(written): \(archive.warningSummary)")
    }

    /// A deck whose one slide, behind an extra field as large as one can be, is named by `aliases` more central
    /// headers: each would be read, and its local header copied, once per name.
    static func overlapping(aliases: Int) -> ZipBuilder {
        var slide = ZipBuilder.Entry("ppt/slides/slide1.xml", PPTXFixture.slide([["ONE"]]))
        slide.localExtra = Int(UInt16.max)
        var builder = package
        builder.entries.append(slide)
        builder.aliases = (0..<aliases).map { ("ppt/slides/slide\($0 + 2).xml", of: builder.entries.count - 1) }
        return builder
    }

    /// As many entries as share one local header in `overlapping`: half of what zipMaxEntries allows.
    static let aliasCount = 32_767

    @Test("Entries that share bytes of the file are refused as corrupted before any of them is read",
          .timeLimit(.minutes(1)), arguments: ["zip", "xlsx", "pptx", "docx"])
    func overlapping(as fileExtension: String) async throws {
        let scratch = try Scratch()
        let url = try scratch.write("crafted.\(fileExtension)", data: Self.overlapping(aliases: Self.aliasCount).data())
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        guard fileExtension != "docx" else {
            #expect(content.metadata.keys.filter { $0.hasPrefix("doc:") }.isEmpty, "no core property is read from it")
            return
        }
        #expect(content.warnings.map(\.code) == [.corrupted], "refused as corrupted (\(content.warningSummary))")
        #expect(content.warnings.first?.detail.contains("share") == true,
                "by the directory's check, before ZIPFoundation is given the file: \(content.warningSummary)")
        #expect(!content.text.contains("ONE"), "no alias of the shared slide is read")
    }

    @Test("An archive that lists more than zipMaxEntries is refused as too large")
    func limits() async throws {
        let scratch = try Scratch()
        let entries = ["a.txt", "b.txt", "c.txt"].map { ZipBuilder.Entry($0, "four") }
        let url = try scratch.write("three.zip", data: ZipBuilder(entries: entries).data())
        for (limit, warnings) in [(3, [WarningCode]()), (2, [.tooLarge])] {
            let context = try TestConfig.context { extraction, _ in extraction.zipMaxEntries = limit }
            let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
            #expect(content.warnings.map(\.code) == warnings, "\(limit) entries allowed: \(content.warningSummary)")
            #expect(content.attachments.count == (warnings.isEmpty ? 3 : 0), "\(limit) allowed: listed only within the limit")
        }
    }

    @Test("An entry's name is UTF-8 when its bytes are, with the flag or without, else code page 437, and composed")
    func names() async throws {
        let scratch = try Scratch()
        let entries = [
            ZipBuilder.Entry(rawName: Array("Счёт.pdf".utf8), utf8Name: false),
            // "Façade.txt" in code page 437, where 0x87 is ç.
            ZipBuilder.Entry(rawName: [0x46, 0x61, 0x87, 0x61, 0x64, 0x65, 0x2E, 0x74, 0x78, 0x74], utf8Name: false),
            ZipBuilder.Entry(rawName: Array("Cafe\u{0301}.txt".utf8), utf8Name: true),
        ]
        let url = try scratch.write("names.zip", data: ZipBuilder(entries: entries).data())
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.attachments.map { Array($0.utf8) } == ["Счёт.pdf", "Façade.txt", "Café.txt"].map { Array($0.utf8) },
                "a UTF-8 name without the flag is not read as code page 437, a code page 437 name is, and every name is composed")
    }

    @Test("An encrypted entry is never read, and the entries after it are read as themselves")
    func encryptedEntries() async throws {
        let scratch = try Scratch()
        var secret = ZipBuilder.Entry("docProps/custom.xml", "<sealed/>")
        secret.encrypted = true
        var sealedSlide = ZipBuilder.Entry("ppt/slides/slide3.xml", PPTXFixture.slide([["THREE"]]))
        sealedSlide.encrypted = true
        let deck = ZipBuilder(entries: [secret, ZipBuilder.Entry("ppt/slides/slide1.xml", PPTXFixture.slide([["ONE"]])),
                                        ZipBuilder.Entry("ppt/slides/slide2.xml", PPTXFixture.slide([["TWO"]])), sealedSlide])
        let url = try scratch.write("sealed.pptx", data: deck.data())
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.text == "Slide 1\nONE\n\nSlide 2\nTWO",
                "each slide is read from its own entry, past an encrypted one, and the encrypted slide is not read")
        #expect(content.warnings.map(\.code) == [.encrypted], "the encrypted slide is noted (\(content.warningSummary))")
        #expect(content.warnings.first?.detail.contains("ppt/slides/slide3.xml") == true, "by its name")
    }

    @Test("A deck of many entries is read in one pass over them, not one pass for each slide", .timeLimit(.minutes(1)))
    func manyEntries() async throws {
        let scratch = try Scratch()
        let slides = (1...1_000).map { ZipBuilder.Entry("ppt/slides/slide\($0).xml", PPTXFixture.slide([["Slide text \($0)"]])) }
        let padding = (1...19_000).map { ZipBuilder.Entry("ppt/media/image\($0).png") }
        let url = try scratch.write("long.pptx", data: ZipBuilder(entries: padding + slides).data())
        let context = try TestConfig.context { extraction, _ in extraction.pptxMaxSlides = 1_000 }
        let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(content.text.hasSuffix("Slide 1000\nSlide text 1000"), "every slide is read, the last after 20,000 entries")
    }

    @Test("An archive written entry by entry is listed with each entry's declared size and their total")
    func listed() async throws {
        let scratch = try Scratch()
        let entries = [ZipBuilder.Entry("fatura.pdf", "%PDF-1.4"), ZipBuilder.Entry("notas/leia.txt", "olá")]
        let url = try scratch.write("bundle.zip", data: ZipBuilder(entries: entries).data())
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.attachments == ["fatura.pdf", "notas/leia.txt"], "each entry is listed, in the archive's order")
        #expect(content.text.contains("fatura.pdf\t8"), "with the size it declares")
        #expect(content.metadata["archive:uncompressedBytes"] == "12", "and the sizes add up to the total")
        #expect(content.warnings.isEmpty, "a well-formed archive is listed without warnings: \(content.warningSummary)")
    }
}
