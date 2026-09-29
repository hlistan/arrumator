import AppKit
import ArrumatorCore
import ArrumatorTesting
@testable import ArrumatorExtract
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision

/// Test inputs generated at runtime into a private temporary directory.
struct Scratch {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arrumator-extract-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: Text files

    @discardableResult
    func write(_ name: String, _ text: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = url(name)
        guard let data = text.data(using: encoding) else { throw FixtureError.encoding(name) }
        try data.write(to: url)
        return url
    }

    @discardableResult
    func write(_ name: String, data: Data) throws -> URL {
        let url = url(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    // MARK: Images and PDFs

    static let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)

    /// Black text on white, one line per entry, drawn with Helvetica (covers Latin and Cyrillic).
    static func textImage(_ lines: [String], width: Int = 1654, height: Int = 2339, fontSize: CGFloat = 40) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw FixtureError.render }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(lines, in: context, top: CGFloat(height) - fontSize * 3, left: fontSize * 3, fontSize: fontSize)
        guard let image = context.makeImage() else { throw FixtureError.render }
        return image
    }

    private static func draw(_ lines: [String], in context: CGContext, top: CGFloat, left: CGFloat, fontSize: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var y = top
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: left, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            y -= fontSize * 1.8
        }
    }

    @discardableResult
    func writeImage(_ name: String, _ image: CGImage, type: UTType = .png,
                    properties: [CFString: Any] = [:]) throws -> URL {
        let url = url(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw FixtureError.render }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.render }
        return url
    }

    /// A PDF with a real text layer: one page per entry of `pages`.
    @discardableResult
    func writeTextPDF(_ name: String, pages: [[String]], password: String? = nil,
                      info: [CFString: Any] = [:]) throws -> URL {
        let url = url(name)
        var auxiliary = info
        if let password {
            auxiliary[kCGPDFContextUserPassword] = password
            auxiliary[kCGPDFContextOwnerPassword] = password + "-owner"
        }
        var box = Self.a4
        guard let context = CGContext(url as CFURL, mediaBox: &box, auxiliary as CFDictionary) else {
            throw FixtureError.render
        }
        for lines in pages {
            context.beginPDFPage(nil)
            Self.draw(lines, in: context, top: box.height - 72, left: 56, fontSize: 12)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A "scanned" PDF: each page is only a full-page raster image of the text, no text layer.
    @discardableResult
    func writeImagePDF(_ name: String, pages: [[String]]) throws -> URL {
        let url = url(name)
        var box = Self.a4
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw FixtureError.render }
        for lines in pages {
            let image = try Self.textImage(lines)
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    // MARK: Office and archives

    @discardableResult
    func writeDocx(_ name: String, text: String, title: String, author: String) throws -> URL {
        let attributed = NSAttributedString(string: text)
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.officeOpenXML, .title: title, .author: author,
        ])
        return try write(name, data: data)
    }

    /// Zips `files` (relative path → contents) with `/usr/bin/zip`.
    @discardableResult
    func writeZip(_ name: String, files: [String: String]) throws -> URL {
        let root = url("zip-src-\(UUID().uuidString)")
        for (path, contents) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        let output = url(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", "-X", "-r", output.path] + files.keys.sorted()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError.zip(process.terminationStatus) }
        return output
    }
}

enum FixtureError: Error {
    case encoding(String)
    case render
    case zip(Int32)
}

// MARK: Configuration

enum TestConfig {
    static func pipeline() throws -> PipelineConfig { try PipelineConfig.bundledDefaults() }

    static func context(vision: VisionModelOptions? = nil,
                        _ adjust: (inout ExtractionConfig, inout EntityConfig) -> Void = { _, _ in }) throws -> ExtractionContext {
        let pipeline = try pipeline()
        var extraction = pipeline.extraction
        var entities = pipeline.entities
        adjust(&extraction, &entities)
        return ExtractionContext(config: extraction, entities: entities, vision: vision)
    }

    static func visionOptions() throws -> VisionModelOptions {
        let pipeline = try pipeline()
        return VisionModelOptions(model: "gemma-test", keepAlive: "1m", numPredict: pipeline.classification.vlmNumPredict, numCtx: 12288,
                                  options: pipeline.classification.llmOptions)
    }
}

/// Whether Vision can read text on this machine at all. GitHub's runners are virtual Macs where every text recognition
/// throws (`TextRecognition.CRImageReaderError` 9 on the default device, an unknown error on the CPU), so the tests that
/// need real OCR are skipped there, with this reason, and run on every physical Mac: before each push (AGENTS.md §8).
/// The probe asks Vision directly, not `OCRService`, so a defect in Arrumator's own OCR fails those tests instead of
/// skipping them.
enum VisionOCR {
    static let unavailable: Comment = "needs Vision text recognition, which this machine cannot run (virtual Macs cannot)"
    static let available = Task<Bool, Never> {
        guard let image = try? Scratch.textImage(["Arrumator"], width: 800, height: 200, fontSize: 60),
              let lines = try? await RecognizeTextRequest().perform(on: image) else { return false }
        return !lines.isEmpty
    }
}

extension ExtractedContent {
    /// What went wrong while reading, for expectation messages: an OCR failure shows its error here, which tells
    /// Vision failing on a machine apart from Vision finding no text.
    var warningSummary: String {
        warnings.isEmpty ? "no warnings" : warnings.map { "\($0.code.rawValue): \($0.detail)" }.joined(separator: "; ")
    }
}

// MARK: Ollama mock

extension MockOllama {
    /// What a model that can describe images reports, as the vision extractor checks before asking it.
    static let visionCapabilities = ["completion", "vision", "thinking"]
}
