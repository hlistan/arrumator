import ArrumatorCore
@testable import ArrumatorExtract
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite("Registry, dispatch and tools")
struct RegistryTests {
    private let registry = ExtractorRegistry()

    @Test("Dispatch prefers exact types, then the most specific conformance")
    func dispatch() throws {
        func name(_ ext: String) throws -> String {
            registry.extractor(for: try #require(UTType(filenameExtension: ext))).name
        }
        #expect(try name("pdf") == "pdf")
        #expect(try name("docx") == "textutil")
        #expect(try name("rtf") == "textutil")
        #expect(try name("html") == "textutil")
        #expect(try name("xlsx") == "xlsx")
        #expect(try name("pptx") == "pptx")
        #expect(try name("csv") == "plain-text")
        #expect(try name("log") == "plain-text")
        #expect(try name("heic") == "image")
        #expect(try name("svg") == "quicklook")
        #expect(try name("numbers") == "quicklook")
        #expect(try name("eml") == "email")
        #expect(try name("zip") == "archive")
        #expect(try name("7z") == "archive")
        #expect(try name("mp3") == "media")
        #expect(try name("mov") == "media")
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
        #expect(content.source.utType == UTType.pdf.identifier)
        #expect(content.kind == .pdfText)
        #expect(content.text.contains("Downloaded statement"))
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
        #expect(status == 0)
        let content = try await registry.extract(url, sha256: "deadbeef", context: try TestConfig.context(), trace: .disabled)
        #expect(content.source.whereFroms == origins)
        #expect(content.source.originalFilename == "note.txt")
        #expect(content.source.fileExtension == "txt")
        #expect(content.source.byteSize == Int64("Plain note for the archive.".utf8.count))
    }

    @Test("Text is NFC-normalised and capped at maxIndexChars with a warning")
    func capping() async throws {
        let scratch = try Scratch()
        let decomposed = "Informac\u{0327}a\u{0303}o " + String(repeating: "texto longo ", count: 50)
        let url = try scratch.write("long.txt", decomposed)
        let context = try TestConfig.context { extraction, _ in extraction.maxIndexChars = 40 }
        let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(content.text.count == 40)
        #expect(content.text.hasPrefix("Informação"))
        #expect(content.textTruncated)
        #expect(content.hasWarning(.textTruncated))
    }

    @Test("Oversized files are metadata-only with tooLarge")
    func tooLarge() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeTextPDF("big.pdf", pages: [["Big document"]])
        let context = try TestConfig.context { extraction, _ in extraction.largeFileBytes = 10 }
        let content = try await registry.extract(url, sha256: "x", context: context, trace: .disabled)
        #expect(content.hasWarning(.tooLarge))
        #expect(content.extractorName == "metadata-only")
        #expect(content.textOrigin == .metadataOnly)
    }

    @Test("Unknown binary data is metadata-only with unsupportedFormat")
    func unsupported() async throws {
        let scratch = try Scratch()
        let url = try scratch.write("blob.qqzz", data: Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 37) }))
        let content = try await registry.extract(url, sha256: "x", context: try TestConfig.context(), trace: .disabled)
        #expect(content.hasWarning(.unsupportedFormat))
        #expect(content.textOrigin == .metadataOnly)
        #expect(content.entities.documentDate?.source == .fileCreated)
    }

    @Test("Missing files and cancellation are hard errors")
    func hardErrors() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf")
        await #expect {
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
        await #expect {
            _ = try await task.value
        } throws: { error in
            guard case .cancelled? = error as? ExtractionError else { return false }
            return true
        }
    }

    @Test("ShellRunner drains large output under a cap and kills on timeout")
    func shell() async throws {
        let runner = ShellRunner()
        let flood = try await runner.run(URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["arrumator"], timeout: 0.5,
                                         killGrace: 0.5, outputCap: 4096)
        #expect(flood.timedOut)
        #expect(flood.stdoutTruncated)
        #expect(flood.stdout.count == 4096)
        let echo = try await runner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["olá"], timeout: 5, killGrace: 1,
                                        outputCap: 1024)
        #expect(echo.status == 0)
        #expect(String(decoding: echo.stdout, as: UTF8.self) == "olá\n")
        #expect(!echo.timedOut)
    }

    @Test("Deadline returns the value in time and throws after the deadline")
    func deadline() async throws {
        #expect(try await Deadline.run(seconds: 5) { 42 } == 42)
        await #expect(throws: DeadlineExceeded.self) {
            try await Deadline.run(seconds: 0.05) {
                try await Task.sleep(for: .seconds(5))
                return 0
            }
        }
    }

    @Test("Smoke: print the extracted JSON of a generated invoice",
          .enabled(if: RuntimeEnvironment.current.live))
    func smoke() async throws {
        let scratch = try Scratch()
        let text = try scratch.writeTextPDF("smoke.pdf", pages: [[
            "EDP Comercial - Comercialização de Energia, S.A.", "Fatura n.º FT 2026/0042",
            "Data de emissão: 20/05/2026", "Data de vencimento: 10/06/2026", "NIF: 503 504 564",
            "N.º de cliente: 1234 5678", "IBAN PT50 0002 0123 1234 5678 9015 4", "Total a pagar: 45,90 €",
        ]])
        let scan = try scratch.writeImagePDF("smoke-scan.pdf", pages: [[
            "ООО «Ромашка»", "Счёт № 15 от 15 мая 2024 г.", "ИНН 7707083893", "Итого: 12 500,00 руб.",
        ]])
        let sink = MemoryTraceSink()
        for url in [text, scan] {
            let content = try await registry.extract(url, sha256: "smoke", context: try TestConfig.context(),
                                                     trace: TraceContext(traceID: 1, sink: sink))
            print(JSON.string(content, pretty: true))
        }
        for step in await sink.steps {
            print("TRACE \(step.stage.rawValue) \(step.status.rawValue) \(Int(step.durationMs)) ms")
            print("  in:  \(step.input ?? "-")")
            print("  out: \(step.output ?? "-")")
        }
    }
}
