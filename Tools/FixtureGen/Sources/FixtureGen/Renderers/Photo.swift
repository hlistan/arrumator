import AppKit
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// A thermal till receipt, `columns` monospace characters wide.
struct Receipt: Sendable {
    let columns: Int
    let lines: [ReceiptLine]
}

enum ReceiptLine: Sendable {
    case centered(String, bold: Bool = false)
    case text(String)
    /// Label on the left, amount flush right.
    case amount(String, String, bold: Bool = false)
    case divider
    case blank
    /// Printed 2-D code (pseudo QR; not decodable).
    case code
}

extension Receipt {
    var plainText: String {
        lines.map { line in
            switch line {
            case .centered(let text, _), .text(let text): text
            case .amount(let label, let value, _): "\(label) \(value)"
            case .divider, .blank, .code: ""
            }
        }.joined(separator: "\n")
    }
}

/// A phone photo of a receipt or card lying on a table.
struct Photo: Sendable {
    enum Subject: Sendable {
        case receipt(Receipt)
        case card(Card)
    }

    enum Format: Sendable {
        case jpeg, heic
    }

    let subject: Subject
    let format: Format
    /// Written as EXIF DateTimeOriginal/DateTimeDigitized with its offset.
    let taken: DateTimeStamp
}

struct PhotoRenderer {
    let settings: RenderSettings

    func render(_ photo: Photo, fake: inout Fake) -> Data {
        let subject: CGImage
        let canvas: CGSize
        switch photo.subject {
        case .receipt(let receipt):
            subject = ReceiptRenderer(settings: settings).image(receipt, fake: &fake)
            canvas = settings.photo.portraitCanvas
        case .card(let card):
            subject = CardRenderer(settings: settings).image(card, scale: settings.photo.cardPixelsPerMillimetre, fake: &fake)
            canvas = settings.photo.landscapeCanvas
        }
        let context = Raster.makeContext()
        let scene = compose(subject, canvas: canvas, fake: &fake)
        var pixels = PixelBuffer(rendering: scene, bounds: CGRect(origin: .zero, size: canvas), layout: .rgba, context: context)
        pixels.addNoise(amplitude: settings.photo.noiseAmplitude, fake: &fake)
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: photo.taken.exif,
                kCGImagePropertyExifDateTimeDigitized: photo.taken.exif,
                kCGImagePropertyExifOffsetTimeOriginal: photo.taken.exifOffset,
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFSoftware: settings.photo.software,
            ],
        ]
        switch photo.format {
        case .jpeg:
            return Raster.encode(pixels.cgImage, as: .jpeg, quality: settings.photo.jpegQuality, properties: properties)
        case .heic:
            return Raster.encode(pixels.cgImage, as: .heic, quality: settings.photo.heicQuality, properties: properties)
        }
    }

    /// Places the subject on a table with a keystone perspective, a soft drop shadow and lens vignetting.
    private func compose(_ subject: CGImage, canvas: CGSize, fake: inout Fake) -> CIImage {
        let photo = settings.photo
        let bounds = CGRect(origin: .zero, size: canvas)
        let table = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: canvas.height),
            "inputPoint1": CIVector(x: 0, y: 0),
            "inputColor0": CIColor(cgColor: photo.tableTop.cgColor),
            "inputColor1": CIColor(cgColor: photo.tableBottom.cgColor),
        ])!.outputImage!.cropped(to: bounds)

        let fit = min(canvas.width * photo.subjectFill / CGFloat(subject.width),
                      canvas.height * photo.subjectFill / CGFloat(subject.height))
        let width = CGFloat(subject.width) * fit
        let height = CGFloat(subject.height) * fit
        let centre = CGPoint(x: canvas.width / 2 + CGFloat(fake.triangular() * photo.offsetJitter) * canvas.width,
                             y: canvas.height / 2 + CGFloat(fake.triangular() * photo.offsetJitter) * canvas.height)
        let keystone = CGFloat(fake.double(photo.keystone)) * width
        // Core Image coordinates: origin bottom-left. The far (top) edge is narrower.
        var corners = [
            CGPoint(x: centre.x - width / 2 + keystone, y: centre.y + height / 2),
            CGPoint(x: centre.x + width / 2 - keystone, y: centre.y + height / 2),
            CGPoint(x: centre.x - width / 2, y: centre.y - height / 2),
            CGPoint(x: centre.x + width / 2, y: centre.y - height / 2),
        ]
        let angle = fake.double(photo.rotationDegrees) * fake.sign() * .pi / 180
        let jitter = photo.cornerJitter * Double(max(width, height))
        corners = corners.map { point in
            let dx = point.x - centre.x
            let dy = point.y - centre.y
            return CGPoint(x: centre.x + dx * cos(angle) - dy * sin(angle) + CGFloat(fake.triangular() * jitter),
                           y: centre.y + dx * sin(angle) + dy * cos(angle) + CGFloat(fake.triangular() * jitter))
        }
        // A transparent margin keeps the warp's edge sampling from smearing the paper across the table.
        let margin = photo.subjectMargin
        let padded = CIImage(cgImage: subject)
            .transformed(by: CGAffineTransform(translationX: margin, y: margin))
            .composited(over: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(subject.width) + 2 * margin,
                                                                           height: CGFloat(subject.height) + 2 * margin)))
        let placed = padded.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: corners[0]),
            "inputTopRight": CIVector(cgPoint: corners[1]),
            "inputBottomLeft": CIVector(cgPoint: corners[2]),
            "inputBottomRight": CIVector(cgPoint: corners[3]),
        ])
        let shadow = placed
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: photo.shadowOpacity),
            ])
            .transformed(by: CGAffineTransform(translationX: photo.shadowOffset.width, y: photo.shadowOffset.height))
            .applyingGaussianBlur(sigma: photo.shadowRadius)
        return placed
            .composited(over: shadow)
            .composited(over: table)
            .cropped(to: bounds)
            .applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: photo.vignetteIntensity,
                kCIInputRadiusKey: photo.vignetteRadius,
            ])
            .clampedToExtent()
            .applyingGaussianBlur(sigma: photo.blurRadius)
            .cropped(to: bounds)
    }
}

/// Prints a receipt onto thermal paper with torn top and bottom edges.
struct ReceiptRenderer {
    let settings: RenderSettings

    func image(_ receipt: Receipt, fake: inout Fake) -> CGImage {
        let photo = settings.photo
        let regular = Typeface.font(.mono, bold: false, size: photo.receiptFontSize, typography: settings.typography)
        let bold = Typeface.font(.mono, bold: true, size: photo.receiptFontSize, typography: settings.typography)
        let advance = CTFontGetAdvancesForGlyphs(regular, .horizontal, [CTFontGetGlyphWithName(regular, "M" as CFString)], nil, 1)
        let codeSide = CGFloat(ReceiptRenderer.codeModules) * photo.receiptQRModule
        let width = Int((CGFloat(receipt.columns) * advance + 2 * photo.receiptMargin).rounded())
        let contentHeight = receipt.lines.reduce(CGFloat(0)) { total, line in
            if case .code = line { return total + codeSide + photo.receiptLineHeight }
            return total + photo.receiptLineHeight
        }
        let height = Int((contentHeight + 2 * photo.receiptMargin).rounded())
        let context = Raster.canvas(width: width, height: height, gray: false)

        // Paper with zig-zag tear lines (y up in this context).
        let tooth = photo.receiptTearTooth
        let paper = CGMutablePath()
        paper.move(to: CGPoint(x: 0, y: tooth))
        var x: CGFloat = 0
        while x < CGFloat(width) {
            paper.addLine(to: CGPoint(x: x + tooth / 2, y: CGFloat(fake.double(0...0.4)) * tooth))
            paper.addLine(to: CGPoint(x: x + tooth, y: tooth))
            x += tooth
        }
        x = CGFloat(width)
        while x > 0 {
            paper.addLine(to: CGPoint(x: x - tooth / 2, y: CGFloat(height) - CGFloat(fake.double(0...0.4)) * tooth))
            paper.addLine(to: CGPoint(x: x - tooth, y: CGFloat(height) - tooth))
            x -= tooth
        }
        paper.closeSubpath()
        context.addPath(paper)
        context.setFillColor(photo.paper.cgColor)
        context.fillPath()

        let ink = NSColor(cgColor: photo.thermalInk.cgColor)!
        var baseline = CGFloat(height) - photo.receiptMargin - photo.receiptLineHeight * 0.8
        for line in receipt.lines {
            let text: String
            let isBold: Bool
            switch line {
            case .centered(let value, let strong):
                let padding = max(0, (receipt.columns - value.count) / 2)
                text = String(repeating: " ", count: padding) + value
                isBold = strong
            case .text(let value):
                text = value
                isBold = false
            case .amount(let label, let value, let strong):
                let room = receipt.columns - value.count - 1
                let trimmed = label.count > room ? String(label.prefix(room)) : label
                text = trimmed + String(repeating: " ", count: receipt.columns - trimmed.count - value.count) + value
                isBold = strong
            case .divider:
                text = String(repeating: "-", count: receipt.columns)
                isBold = false
            case .blank:
                text = ""
                isBold = false
            case .code:
                drawCode(in: context, centreX: CGFloat(width) / 2, top: baseline + photo.receiptLineHeight * 0.6, fake: &fake)
                baseline -= codeSide + photo.receiptLineHeight
                continue
            }
            precondition(text.count <= receipt.columns, "receipt line wider than the paper: \(text)")
            let attributed = NSAttributedString(string: text, attributes: [.font: isBold ? bold : regular, .foregroundColor: ink])
            context.textPosition = CGPoint(x: photo.receiptMargin, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            baseline -= photo.receiptLineHeight
        }
        return context.makeImage()!
    }

    static let codeModules = 25

    /// Pseudo-random modules with the three finder squares of a QR code (the ATCUD code on Portuguese receipts).
    private func drawCode(in context: CGContext, centreX: CGFloat, top: CGFloat, fake: inout Fake) {
        let module = settings.photo.receiptQRModule
        let count = ReceiptRenderer.codeModules
        let left = centreX - CGFloat(count) * module / 2
        func isFinder(_ column: Int, _ row: Int) -> Bool? {
            for (originColumn, originRow) in [(0, 0), (count - 7, 0), (0, count - 7)] {
                let c = column - originColumn
                let r = row - originRow
                if (0..<7).contains(c) && (0..<7).contains(r) {
                    let ring = min(c, r, 6 - c, 6 - r)
                    return ring != 1
                }
                if (-1...7).contains(c) && (-1...7).contains(r) { return false }
            }
            return nil
        }
        context.setFillColor(settings.photo.thermalInk.cgColor)
        for row in 0..<count {
            for column in 0..<count {
                let dark = isFinder(column, row) ?? (fake.next() & 1 == 1)
                if dark {
                    context.fill(CGRect(x: left + CGFloat(column) * module, y: top - CGFloat(row + 1) * module,
                                        width: module, height: module))
                }
            }
        }
    }
}
