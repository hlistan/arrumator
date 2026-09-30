import ArrumatorCore
@testable import ArrumatorExtract
import ArrumatorTesting
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite("Registry, dispatch and tools")
struct RegistryTests {
    private let registry: ExtractorRegistry

    init() throws { registry = try TestConfig.registry() }

    @Test("Dispatch prefers exact types, then the most specific conformance")
    func dispatch() throws {
        func name(_ ext: String) throws -> String {
            registry.extractor(for: try #require(UTType(filenameExtension: ext))).name
        }
        #expect(try name("pdf") == "pdf", "a PDF has its own extractor")
        #expect(try name("docx") == "textutil", "Word documents go to textutil")
        #expect(try name("rtf") == "textutil", "rich text goes to textutil")
        #expect(try name("html") == "textutil", "HTML goes to textutil, which strips its markup")
        #expect(try name("xlsx") == "xlsx", "a spreadsheet has its own reader, not textutil")
        #expect(try name("pptx") == "pptx", "a presentation has its own reader, not textutil")
        #expect(try name("csv") == "plain-text", "CSV is read as text")
        #expect(try name("log") == "plain-text", "a log conforms to plain text and is read as text")
        #expect(try name("heic") == "image", "an iPhone photo is an image to OCR")
        #expect(try name("svg") == "quicklook", "SVG, a vector image, goes to Quick Look, not to OCR")
        #expect(try name("numbers") == "quicklook", "iWork files go to Quick Look")
        #expect(try name("eml") == "email", "a saved e-mail goes to the e-mail reader")
        #expect(try name("zip") == "archive", "a zip goes to the archive extractor")
        #expect(try name("7z") == "archive", "other archives go there too, to be listed as metadata")
        #expect(try name("mp3") == "media", "audio is media")
        #expect(try name("mov") == "media", "video is media")
    }

    @Test("Files without an extension are recognised by their magic bytes")
    func sniffing() async throws {
        let scratch = try Scratch()
        let pdf = try scratch.writeTextPDF("download.pdf", pages: [[
            "Downloaded statement for March", "Opening balance, card payments and transfers for the month.",
        ]])
        let bare = scratch.url("download")
        try FileManager.default.moveItem(at: pdf, to: bare)
        let content = try await registry.extract(bare, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.source.utType == UTType.pdf.identifier, "a PDF without an extension is recognised by its %PDF header")
        #expect(content.kind == .pdfText, "and is read as the PDF it is")
        #expect(content.text.contains("Downloaded statement"), "its text layer is read")
    }

    @Test("Source facts include kMDItemWhereFroms from the binary plist xattr")
    func whereFroms() async throws {
        let scratch = try Scratch()
        let url = try scratch.write("note.txt", "Plain note for the archive.")
        let origins = ["https://example.com/files/note.txt", "https://example.com/"]
        let plist = try PropertyListSerialization.data(fromPropertyList: origins, format: .binary, options: 0)
        let status = plist.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0)
        }
        #expect(status == 0, "the fixture sets the download origin as Safari does")
        let content = try await registry.extract(url, sha256: "deadbeef", context: try TestConfig.context(), trace: .disabled)
        #expect(content.source.whereFroms == origins, "where a file was downloaded from is kept, in order")
        #expect(content.source.originalFilename == "note.txt", "the name the file arrived with is kept")
        #expect(content.source.fileExtension == "txt", "the extension is kept without its dot")
        #expect(content.source.byteSize == Int64("Plain note for the archive.".utf8.count), "the size is the bytes on disk")
    }

    @Test("Text is NFC-normalised and capped at maxIndexChars with a warning")
    func capping() async throws {
        let scratch = try Scratch()
        let decomposed = "Informac\u{0327}a\u{0303}o " + String(repeating: "texto longo ", count: 50)
        let url = try scratch.write("long.txt", decomposed)
        let context = try TestConfig.context { extraction, _ in extraction.maxIndexChars = 40 }
        let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(content.text.count == 40, "text is cut at maxIndexChars characters")
        #expect(content.text.hasPrefix("Informação"), "decomposed accents are composed, so they count and search as one character")
        #expect(content.textTruncated, "the content says it was cut")
        #expect(content.warnings.map(\.code) == [.textTruncated], "the cut is the one warning")
    }

    @Test("Oversized files are metadata-only with tooLarge")
    func tooLarge() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeTextPDF("big.pdf", pages: [["Big document"]])
        let context = try TestConfig.context { extraction, _ in extraction.largeFileBytes = 10 }
        let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(content.warnings.map(\.code) == [.tooLarge], "a file over largeFileBytes is not read, and the warning says so")
        #expect(content.extractorName == "metadata-only", "an oversized file skips its own extractor")
        #expect(content.textOrigin == .metadataOnly, "an oversized file is described by its metadata alone")
    }

    @Test("Unknown binary data is metadata-only with unsupportedFormat")
    func unsupported() async throws {
        let scratch = try Scratch()
        let url = try scratch.write("blob.qqzz", data: Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 37) }))
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.warnings.map(\.code) == [.unsupportedFormat], "unknown data is filed with a warning, not failed")
        #expect(content.textOrigin == .metadataOnly, "unknown data is described by its metadata alone")
        #expect(content.entities.documentDate?.source == .fileCreated, "without text, the file's creation date dates it")
    }

    @Test("Missing files and cancellation are hard errors")
    func hardErrors() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf")
        await #expect("a missing file is an error, not an empty document") {
            _ = try await registry.extract(missing, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        } throws: { error in
            guard case .fileUnreadable? = error as? ExtractionError else { return false }
            return true
        }
        let scratch = try Scratch()
        let url = try scratch.write("note.txt", "text")
        let context = try TestConfig.context()
        let registry = registry
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        }
        await #expect("a cancelled job stops with an error, not with partial content") {
            _ = try await task.value
        } throws: { error in
            guard case .cancelled? = error as? ExtractionError else { return false }
            return true
        }
    }

    @Test("A tool's output is capped without blocking it")
    func shellCapsOutput() async throws {
        let runner = ShellRunner(time: TestTime(.blocks))
        let flood = try await runner.run(URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "100000", "/dev/zero"], timeout: 30,
                                         killGrace: 1, outputCap: 4096)
        #expect(flood.stdoutTruncated && flood.stdout.count == 4096, "a chatty tool is read to its end, and only the cap is kept")
        #expect(!flood.timedOut && flood.status == 0, "a tool that finishes is not killed")
        let echo = try await runner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["olá"], timeout: 30, killGrace: 1, outputCap: 1024)
        #expect(echo.status == 0 && String(decoding: echo.stdout, as: UTF8.self) == "olá\n" && !echo.timedOut,
                "arguments go to the tool as they are, with no shell between")
    }

    @Test("A tool that outruns its timeout is killed")
    func shellTimesOut() async throws {
        let endless = try await ShellRunner(time: TestTime(.advances))
            .run(URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["arrumator"], timeout: 30, killGrace: 1, outputCap: 4096)
        #expect(endless.timedOut, "a tool that never ends is stopped at its timeout, so extraction goes on")
        #expect(endless.status != 0, "and its exit says it was killed")
    }
}
