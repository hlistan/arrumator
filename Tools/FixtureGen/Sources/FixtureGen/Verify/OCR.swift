import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Vision text recognition, configured like the app's OCR service (accurate, en/ru/pt, language correction).
struct OCREngine {
    func recognize(_ image: CGImage, primary: Language) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = OCREngine.languages(primary: primary)
        let observations = try await request.perform(on: image)
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// The fixture's own language first, like the app orders its guesses.
    private static func languages(primary: Language) -> [Locale.Language] {
        let all: [(Language, String)] = [(.en, "en-US"), (.ru, "ru-RU"), (.pt, "pt-BR")]
        let ordered = all.filter { $0.0 == primary } + all.filter { $0.0 != primary }
        return ordered.map { Locale.Language(identifier: $0.1) }
    }
}

enum ImageProbe {
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func exifDateTimeOriginal(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        return exif[kCGImagePropertyExifDateTimeOriginal] as? String
    }

    /// Rasterises every page of a PDF in grey at `dpi`.
    static func pages(ofPDFAt url: URL, dpi: CGFloat) -> [CGImage] {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return [] }
        return (1...document.numberOfPages).compactMap { number in
            guard let page = document.page(at: number) else { return nil }
            let box = page.getBoxRect(.mediaBox)
            let scale = dpi / 72
            let context = Raster.canvas(width: Int(box.width * scale), height: Int(box.height * scale), gray: true)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
            return context.makeImage()
        }
    }
}
