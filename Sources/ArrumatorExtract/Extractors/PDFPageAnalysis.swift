import ArrumatorCore
import CoreGraphics
import Foundation
import PDFKit

/// Why a PDF page is treated as an image (scanned) page.
enum ImagePageReason: String, Sendable, Encodable {
    case fewCharacters, lowLetterShare, replacementCharacters, fullPageImage
}

/// Text-layer measurements of one page.
struct PageTextQuality: Sendable, Encodable {
    var characters: Int
    /// The characters that are not U+FFFD, the replacement for a glyph the text layer cannot name: how much a page's
    /// text says, to weigh a text layer against what OCR read of the page.
    var readable: Int
    var letterShare: Double
    var replacementShare: Double

    init(_ text: String) {
        var visible = 0
        var letters = 0
        var replacements = 0
        for char in text where !char.isWhitespace {
            visible += 1
            if char.isLetter { letters += 1 }
            if char == "\u{FFFD}" { replacements += 1 }
        }
        characters = visible
        readable = visible - replacements
        letterShare = visible == 0 ? 0 : Double(letters) / Double(visible)
        replacementShare = visible == 0 ? 0 : Double(replacements) / Double(visible)
    }

    /// The first scanned-page rule from `ExtractionConfig.PDF` that this text layer triggers, if any.
    func imagePageReason(_ config: ExtractionConfig.PDF, imageCoverage: () -> Double) -> ImagePageReason? {
        if characters < config.minPageChars { return .fewCharacters }
        if letterShare < config.minLetterShare { return .lowLetterShare }
        if replacementShare > config.maxReplacementShare { return .replacementCharacters }
        if characters < config.imagePageMaxChars, imageCoverage() >= config.fullPageImageCoverage { return .fullPageImage }
        return nil
    }
}

/// A page's text as PDFKit reads it, with text set apart on one of its lines kept apart: two columns side by side, or a
/// label and its value or a table's cells, with a tab between rather than the space PDFKit joins them by, as OCR parts a
/// row's cells, so the model never reads two of them as one ("EDP Comercial" beside "Maria Exemplo"). Two are apart when
/// the gap between the letters either side of a run of spaces is wider than `gap` times their height, on one line. The
/// letters are placed by what PDFKit selects at each place in the text (`selection(for:)`), as the bounds it gives a
/// character by its index drift from the text past a line break: two selections for each run of spaces, in one pass.
enum PDFPageText {
    static func columned(_ page: PDFPage, gap: Double) -> String {
        let text = (page.string ?? "") as NSString
        func isIn(_ set: CharacterSet, _ index: Int) -> Bool {
            Unicode.Scalar(text.character(at: index)).map(set.contains) ?? false
        }
        func letter(_ index: Int) -> CGRect? {
            guard index >= 0, index < text.length, !isIn(.newlines, index),
                  let bounds = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page), !bounds.isEmpty
            else { return nil }
            return bounds
        }
        var parts: [String] = []
        var start = 0
        var index = 0
        while index < text.length {
            guard isIn(.whitespaces, index) else {
                index += 1
                continue
            }
            var end = index
            while end < text.length, isIn(.whitespaces, end) { end += 1 }
            if let before = letter(index - 1), let after = letter(end), apart(before, after, gap: gap) {
                parts.append(text.substring(with: NSRange(location: start, length: index - start)))
                start = end
            }
            index = end
        }
        return (parts + [text.substring(from: start)]).joined(separator: "\t")
    }

    /// Whether `after` stands apart from `before` on their line: the two overlap in height, and the gap from one to the
    /// other is wider than `gap` times the taller.
    static func apart(_ before: CGRect, _ after: CGRect, gap: Double) -> Bool {
        min(before.maxY, after.maxY) > max(before.minY, after.minY)
            && Double(after.minX - before.maxX) > gap * Double(max(before.height, after.height))
    }
}

/// Largest share of the page area covered by a single image XObject drawn directly in the page content stream.
/// Scans the content stream, tracking the current transformation matrix through `q`/`Q`/`cm`.
enum PDFImageCoverage {
    static func largestImageShare(of page: CGPDFPage) -> Double {
        let box = page.getBoxRect(.cropBox)
        let pageArea = Double(box.width * box.height)
        guard pageArea > 0, let table = CGPDFOperatorTableCreate() else { return 0 }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            PDFImageCoverage.state(info)?.push()
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            PDFImageCoverage.state(info)?.pop()
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in (0..<6).reversed() {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3],
                                           tx: values[4], ty: values[5])
            PDFImageCoverage.state(info)?.concatenate(matrix)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name, let state = PDFImageCoverage.state(info) else { return }
            let stream = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
            var xobject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dictionary = CGPDFStreamGetDictionary(xobject) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Image" else { return }
            state.recordImage()
        }
        let state = ScanState(pageArea: pageArea)
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
        return state.largestShare
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> ScanState? {
        info.map { Unmanaged<ScanState>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Mutable scanner state, confined to the synchronous `CGPDFScannerScan` call.
    private final class ScanState {
        private var stack: [CGAffineTransform] = [.identity]
        private let pageArea: Double
        private(set) var largestShare = 0.0

        init(pageArea: Double) { self.pageArea = pageArea }

        func push() { stack.append(stack.last ?? .identity) }
        func pop() { if stack.count > 1 { stack.removeLast() } }
        func concatenate(_ matrix: CGAffineTransform) {
            stack[stack.count - 1] = matrix.concatenating(stack.last ?? .identity)
        }

        /// Images are drawn into the unit square mapped by the current matrix.
        func recordImage() {
            let bounds = CGRect(x: 0, y: 0, width: 1, height: 1).applying(stack.last ?? .identity)
            largestShare = max(largestShare, min(1, Double(bounds.width * bounds.height) / pageArea))
        }
    }
}

/// Renders PDF pages into grayscale bitmaps for OCR.
enum PDFPageRenderer {
    /// DPI for a page of `area` pt²: lower for large formats, higher for small ones.
    static func dpi(forArea area: Double, config: ExtractionConfig.PDF) -> Double {
        if area > config.largePageArea { return config.ocrDPILargePage }
        if area < config.smallPageArea { return config.ocrDPISmallPage }
        return config.ocrDPI
    }

    /// Grayscale, contrast-stretched render of `page` (rotation applied), longest side capped at `ocrMaxPixel`.
    static func render(_ page: PDFPage, config: ExtractionConfig) -> (image: CGImage, dpi: Double)? {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let dpi = dpi(forArea: Double(size.width * size.height), config: config.pdf)
        var scale = dpi / pointsPerInch
        let longest = Double(max(size.width, size.height)) * scale
        if longest > Double(config.pdf.ocrMaxPixel) { scale *= Double(config.pdf.ocrMaxPixel) / longest }
        // A crop box is what the file declares, infinite included: a page that comes to no whole number of pixels is
        // not drawn.
        guard let width = Int(exactly: (Double(size.width) * scale).rounded()),
              let height = Int(exactly: (Double(size.height) * scale).rounded()),
              let context = ImageTools.grayscaleCanvas(width: max(1, width), height: max(1, height)) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = ImageTools.finishGrayscale(context, contrast: config.ocr.contrast) else { return nil }
        return (image, scale * pointsPerInch)
    }

    private static let pointsPerInch = 72.0
}
