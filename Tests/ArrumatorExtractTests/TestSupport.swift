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

    /// A TIFF of several pages, one image each, as a scanner or a fax writes one.
    @discardableResult
    func writeTIFF(_ name: String, pages: [CGImage]) throws -> URL {
        let url = url(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString,
                                                                pages.count, nil) else { throw FixtureError.render }
        for page in pages { CGImageDestinationAddImage(destination, page, nil) }
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.render }
        return url
    }

    /// A grayscale TIFF that declares `width` × `height` pixels in a few hundred kilobytes: each row is a strip of
    /// its own, and every strip is the same Adobe Deflate stream of one black row (TIFF 6.0 §7 and the Adobe
    /// supplement; RFC 1950 and 1951), its row held in a stored block, so nothing needs compressing. `width` is at most
    /// one stored block, 65,535 bytes.
    @discardableResult
    func writeTIFF(_ name: String, declaring width: Int, by height: Int) throws -> URL {
        func le16(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(value).littleEndian, Array.init) }
        func le32(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).littleEndian, Array.init) }
        // zlib header, a final stored block of the row's zero bytes, and their Adler-32 (a = 1, b = width).
        let row = [0x78, 0x01, 0x01] + le16(width) + le16(width ^ 0xFFFF) + [UInt8](repeating: 0, count: width)
            + withUnsafeBytes(of: (UInt32(width % 65_521) << 16 | 1).bigEndian, Array.init)
        let short = 3, long = 4
        let fields: [(tag: Int, type: Int, count: Int)] = [
            (256, long, 1), (257, long, 1), (258, short, 1), (259, short, 1), (262, short, 1),
            (273, long, height), (277, short, 1), (278, long, 1), (279, long, height),
        ]
        let offsets = 8 + 2 + 12 * fields.count + 4
        let counts = offsets + 4 * height
        let rowAt = counts + 4 * height
        // Width, height, 8 bits, Adobe Deflate, black is zero, strip offsets, one sample, one row a strip, strip sizes.
        let values = [width, height, 8, 8, 1, offsets, 1, 1, counts]
        var bytes: [UInt8] = Array("II*\0".utf8) + le32(8) + le16(fields.count)
        for (field, value) in zip(fields, values) {
            bytes += le16(field.tag) + le16(field.type) + le32(field.count)
            bytes += field.type == short ? le16(value) + le16(0) : le32(value)
        }
        bytes += le32(0)
        for _ in 0..<height { bytes += le32(rowAt) }
        for _ in 0..<height { bytes += le32(row.count) }
        return try write(name, data: Data(bytes + row))
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
        let root = try writeTree(files: files, folders: [])
        let output = url(name)
        try Self.run("/usr/bin/zip", ["-q", "-X", "-r", output.path] + files.keys.sorted(), in: root)
        return output
    }

    /// The archivers a Mac has, as a person or an app runs them.
    enum Archiver: String, CaseIterable, Sendable {
        /// `ditto -c -k --sequesterRsrc`, what Finder's Compress runs: data descriptors of 16 bytes.
        case ditto
        /// libarchive's `bsdtar --format zip`: data descriptors of 16 bytes, an empty file's too.
        case bsdtar
        /// `bsdtar --options zip:zip64`: data descriptors of 24 bytes.
        case bsdtarZIP64
        /// Info-ZIP's `zip -r`: no data descriptors.
        case infoZIP
        /// Info-ZIP's `zip -fz`: a ZIP64 extra field on every entry, holding 0 for a folder or an empty file.
        case infoZIPZIP64
    }

    /// `files` (path → contents, "" for an empty file) and the empty `folders`, archived from their root by `archiver`,
    /// with an entry for each folder.
    @discardableResult
    func writeArchive(_ name: String, files: [String: String], folders: [String], with archiver: Archiver) throws -> URL {
        let root = try writeTree(files: files, folders: folders)
        let output = url(name)
        let topLevel = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        switch archiver {
        case .ditto:
            try Self.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", root.path, output.path], in: root)
        case .bsdtar:
            try Self.run("/usr/bin/bsdtar", ["-c", "--format", "zip", "-f", output.path] + topLevel, in: root)
        case .bsdtarZIP64:
            try Self.run("/usr/bin/bsdtar", ["-c", "--format", "zip", "--options", "zip:zip64", "-f", output.path] + topLevel,
                         in: root)
        case .infoZIP:
            try Self.run("/usr/bin/zip", ["-q", "-X", "-r", output.path, "."], in: root)
        case .infoZIPZIP64:
            try Self.run("/usr/bin/zip", ["-q", "-X", "-r", "-fz", output.path, "."], in: root)
        }
        return output
    }

    /// A folder of its own holding `files` and the empty `folders`.
    private func writeTree(files: [String: String], folders: [String]) throws -> URL {
        let root = url("archive-src-\(UUID().uuidString)")
        for (path, contents) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        for folder in folders {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        return root
    }

    private static func run(_ executable: String, _ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = folder
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError.zip(process.terminationStatus) }
    }
}

/// ZIP files written byte by byte (PKWARE, APPNOTE.TXT 6.3.10), their entries stored, with what no archiver writes:
/// ZIP64 sizes and offsets (APPNOTE 4.5.3) that lie, which the central directory gives in place of the real ones.
struct ZipBuilder {
    /// A data descriptor after an entry's data (APPNOTE 4.3.9), in each form a writer may give it: it sets general
    /// purpose bit 3 and leaves the local header's CRC and sizes zero, as a writer that streams does.
    enum Descriptor: Int, CaseIterable, Sendable {
        /// The CRC-32 and 32-bit sizes, without the optional signature: 12 bytes.
        case short = 12
        /// With its signature: 16 bytes, as ditto, bsdtar and jar write it.
        case signed = 16
        /// With 64-bit sizes and no signature: 20 bytes.
        case wide = 20
        /// With its signature and 64-bit sizes: 24 bytes, as bsdtar writes it for ZIP64.
        case wideSigned = 24

        var isWide: Bool { self == .wide || self == .wideSigned }
        var isSigned: Bool { self == .signed || self == .wideSigned }
    }

    struct Entry {
        var name: [UInt8]
        var contents: [UInt8]
        /// General purpose bit 11: the name is UTF-8 (APPNOTE 4.4.4).
        var utf8Name = true
        var zip64Uncompressed: UInt64?
        var zip64Compressed: UInt64?
        var zip64Offset: UInt64?
        /// The data descriptor after the entry's data, if any.
        var descriptor: Descriptor?
        /// A folder: a name ending in `/` and the Unix folder type (APPNOTE 4.4.15).
        var isFolder = false
        /// The compression method recorded (APPNOTE 4.4.5): 0, stored, or 8, deflated, though the bytes are stored.
        var method = 0
        /// General purpose bit 0: the entry is encrypted (APPNOTE 4.4.4). Its bytes are written as they are.
        var encrypted = false
        /// Bytes of an extra field of no known kind (APPNOTE 4.5.1) in the local header, header included: at most 65,535.
        var localExtra = 0

        init(_ name: String, _ contents: String = "") {
            self.name = Array(name.utf8)
            self.contents = Array(contents.utf8)
        }

        init(rawName: [UInt8], utf8Name: Bool) {
            name = rawName
            contents = []
            self.utf8Name = utf8Name
        }

        init(folder name: String) {
            self.init(name)
            isFolder = true
        }

        var isZIP64: Bool { zip64Uncompressed != nil || zip64Compressed != nil || zip64Offset != nil }
        /// Version 4.5, which tells a reader to take a data descriptor's sizes as 64-bit (APPNOTE 4.3.9.2).
        var needsZIP64: Bool { isZIP64 || descriptor?.isWide == true }
    }

    var entries: [Entry]
    /// A ZIP64 end of central directory record (APPNOTE 4.3.14), with its locator, giving this as the central
    /// directory's offset.
    var zip64DirectoryOffset: UInt64?
    /// Central directory headers of their own names that point at the local header of the entry at `of`, after the
    /// entries' own: entries that share their bytes, as an overlapping-file ZIP bomb's do (Fifield, "A better zip bomb",
    /// WOOT 2019).
    var aliases: [(name: String, of: Int)] = []

    func data() -> Data {
        var bytes: [UInt8] = []
        var offsets: [Int] = []
        let checksums = entries.map { Self.crc32($0.contents) }
        for (entry, checksum) in zip(entries, checksums) {
            offsets.append(bytes.count)
            let streamed = entry.descriptor != nil
            bytes += Self.le32(0x0403_4B50) + Self.le16(entry.needsZIP64 ? 45 : 20) + Self.le16(Self.flags(entry))
                + Self.le16(entry.method) + Self.le16(0) + Self.le16(0) + Self.le32(streamed ? 0 : checksum)
                + Self.le32(streamed ? 0 : entry.contents.count) + Self.le32(streamed ? 0 : entry.contents.count)
                + Self.le16(entry.name.count) + Self.le16(entry.localExtra) + entry.name
                + Self.unknownExtraField(entry.localExtra) + entry.contents
            if let descriptor = entry.descriptor {
                let size = UInt64(entry.contents.count)
                bytes += (descriptor.isSigned ? Self.le32(0x0807_4B50) : []) + Self.le32(checksum)
                    + (descriptor.isWide ? Self.le64(size) + Self.le64(size) : Self.le32(Int(size)) + Self.le32(Int(size)))
            }
        }
        let directoryStart = bytes.count
        // Each central header: the entry it describes, the name it gives it.
        let headers = entries.indices.map { ($0, entries[$0].name) } + aliases.map { ($0.of, Array($0.name.utf8)) }
        for (index, name) in headers {
            let entry = entries[index], offset = offsets[index]
            let wide = [entry.zip64Uncompressed, entry.zip64Compressed, entry.zip64Offset].compactMap { $0 }
            let extra = wide.isEmpty ? [] : Self.le16(1) + Self.le16(8 * wide.count) + wide.flatMap(Self.le64)
            // Made on Unix (APPNOTE 4.4.2), a regular file or a folder (its mode in the high half of the external
            // attributes).
            let mode = entry.isFolder ? 0o040755 : 0o100644
            bytes += Self.le32(0x0201_4B50) + Self.le16(0x0314) + Self.le16(entry.needsZIP64 ? 45 : 20)
                + Self.le16(Self.flags(entry)) + Self.le16(entry.method) + Self.le16(0) + Self.le16(0)
                + Self.le32(checksums[index])
                + Self.le32(entry.zip64Compressed == nil ? entry.contents.count : Self.wide)
                + Self.le32(entry.zip64Uncompressed == nil ? entry.contents.count : Self.wide)
                + Self.le16(name.count) + Self.le16(extra.count) + Self.le16(0) + Self.le16(0) + Self.le16(0)
                + Self.le32(mode << 16) + Self.le32(entry.zip64Offset == nil ? offset : Self.wide) + name + extra
        }
        let directorySize = bytes.count - directoryStart
        if let zip64DirectoryOffset {
            let record = bytes.count
            bytes += Self.le32(0x0606_4B50) + Self.le64(44) + Self.le16(45) + Self.le16(45) + Self.le32(0) + Self.le32(0)
                + Self.le64(UInt64(headers.count)) + Self.le64(UInt64(headers.count)) + Self.le64(UInt64(directorySize))
                + Self.le64(zip64DirectoryOffset)
            bytes += Self.le32(0x0706_4B50) + Self.le32(0) + Self.le64(UInt64(record)) + Self.le32(1)
        }
        bytes += Self.le32(0x0605_4B50) + Self.le16(0) + Self.le16(0) + Self.le16(headers.count) + Self.le16(headers.count)
            + Self.le32(directorySize) + Self.le32(zip64DirectoryOffset == nil ? directoryStart : Self.wide) + Self.le16(0)
        return Data(bytes)
    }

    /// What a 32-bit field holds when its value is in the ZIP64 extra field.
    private static let wide = 0xFFFF_FFFF

    /// An extra field of `size` bytes, its four-byte header included, of an ID no reader knows; empty for 0.
    private static func unknownExtraField(_ size: Int) -> [UInt8] {
        size == 0 ? [] : le16(0xCAFE) + le16(size - 4) + [UInt8](repeating: 0, count: size - 4)
    }

    private static func flags(_ entry: Entry) -> Int {
        (entry.utf8Name ? 1 << 11 : 0) | (entry.descriptor != nil ? 1 << 3 : 0) | (entry.encrypted ? 1 : 0)
    }

    private static func le16(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian, Array.init) }
    private static func le32(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian, Array.init) }
    private static func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    private static func le64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }

    /// CRC-32 as ZIP computes it (APPNOTE 4.4.7: the polynomial 0xEDB88320, reflected).
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
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

    /// The registry the app wires, with Vision's own recognizer and the real shell. Its deadlines are measured on time
    /// that never comes (`TestTime(.blocks)`), so real OCR and tools finish however slow the machine; pass
    /// `TestTime(.advances)` for deadlines that expire at once.
    static func registry(ollama: (any OllamaAPI)? = nil, recognizer: any TextRecognizing = VisionTextRecognizer(),
                         time: TestTime = TestTime(.blocks)) throws -> ExtractorRegistry {
        try ExtractorRegistry(ollama: ollama, recognizer: recognizer, shell: ShellRunner(time: time), time: time)
    }

    /// A vision model of its own, asked as the pipeline asks the profile's (`PipelineConfig.extractionContext`).
    static func visionOptions() throws -> VisionModelOptions {
        let pipeline = try pipeline()
        return VisionModelOptions(model: "gemma-test", keepAlive: pipeline.ollama.keepAlive.chat, numPredict: pipeline.analysis.vlmNumPredict,
                                  numCtx: pipeline.analysis.numCtx, options: pipeline.analysis.llmOptions, think: pipeline.analysis.think)
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

/// Stands in for Vision: answers each image with what `answer` reads in it, and records the width of each image it
/// was asked to read, in order.
actor RecordingRecognizer: TextRecognizing {
    private let answer: @Sendable (CGImage) -> String
    private(set) var widths: [Int] = []

    init(answer: @escaping @Sendable (CGImage) -> String = { _ in "" }) { self.answer = answer }

    nonisolated func documentsSupport(_ languages: [String]) -> Bool { true }

    func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation, engine: OCREngine, languages: [String],
                   on device: OCRDevice) async throws -> ArrumatorExtract.RecognizedText {
        widths.append(image.width)
        let text = answer(image)
        return ArrumatorExtract.RecognizedText(text: text, paragraphs: [text], tables: [],
                                               lines: text.isEmpty ? [] : [RecognizedLine(text: text, confidence: 0.9)], languages: languages)
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
