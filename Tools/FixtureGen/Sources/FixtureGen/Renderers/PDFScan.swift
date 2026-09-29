import CoreImage
import UniformTypeIdentifiers

/// Scanned-looking, image-only PDF: the page is rasterised at the scan resolution, skewed, softened, given
/// paper noise, dust and a lid shadow, then embedded as a single grey JPEG per page. There is no text layer,
/// so the app has to OCR it.
struct PDFScanRenderer {
    let settings: RenderSettings

    func render(_ source: ScanSource, key: String, fake: inout Fake) -> Data {
        let pages: [CGImage]
        let info: DocumentInfo
        switch source {
        case .document(let document):
            let printed = PDFTextRenderer(settings: settings)
                .render(document, bodySize: settings.typography.scanBodySize, key: key)
            pages = rasterise(printed)
            info = document.info
        case .card(let card, let cardInfo):
            pages = [cardOnGlass(card, fake: &fake)]
            info = cardInfo
        case .blank(let blankInfo):
            pages = [blankSheet()]
            info = blankInfo
        }
        let context = Raster.makeContext()
        let jpegs = pages.map { page in
            Raster.encode(degrade(page, context: context, fake: &fake), as: .jpeg, quality: settings.scan.jpegQuality)
        }
        // A scanner knows neither title nor author; only the creator entry is set.
        let pdfInfo: [CFString: Any] = [kCGPDFContextCreator: settings.pdf.creator]
        let pageSize = settings.page.size
        let data = PDFCanvas.draw(pageSize: pageSize, info: pdfInfo, pageCount: jpegs.count) { pdf, index in
            // Built from the JPEG data provider, so Quartz embeds the bytes as-is (DCTDecode) instead of re-encoding.
            guard let provider = CGDataProvider(data: jpegs[index] as CFData),
                  let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                      intent: .defaultIntent) else {
                preconditionFailure("could not decode a freshly encoded scan page")
            }
            pdf.draw(image, in: CGRect(origin: .zero, size: pageSize))
        }
        let scanned = info.created.adding(days: fake.int(settings.scan.scanDelayDays))
        return PDFIdentity.pin(data, created: scanned, hour: settings.pdf.metadataHour, key: key)
    }

    private var pixelSize: (width: Int, height: Int) {
        let scale = settings.scan.dpi / 72
        return (Int((settings.page.size.width * scale).rounded()), Int((settings.page.size.height * scale).rounded()))
    }

    private func rasterise(_ pdf: Data) -> [CGImage] {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else {
            preconditionFailure("could not reopen a freshly rendered PDF")
        }
        return (1...document.numberOfPages).map { number in
            let context = whitePage()
            let scale = settings.scan.dpi / 72
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(document.page(at: number)!)
            return context.makeImage()!
        }
    }

    private func cardOnGlass(_ card: Card, fake: inout Fake) -> CGImage {
        let context = whitePage()
        let pixelsPerMillimetre = settings.scan.dpi / 25.4
        let origin = settings.scan.cardOriginMillimetres
        CardRenderer(settings: settings).draw(
            card, in: context, topLeft: CGPoint(x: origin.x * pixelsPerMillimetre, y: origin.y * pixelsPerMillimetre),
            scale: pixelsPerMillimetre, canvasHeight: CGFloat(context.height), fake: &fake)
        return context.makeImage()!
    }

    private func blankSheet() -> CGImage { whitePage().makeImage()! }

    private func whitePage() -> CGContext {
        let size = pixelSize
        let context = Raster.canvas(width: size.width, height: size.height, gray: true)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context
    }

    private func degrade(_ page: CGImage, context: CIContext, fake: inout Fake) -> CGImage {
        let scan = settings.scan
        let source = CIImage(cgImage: page)
        let extent = source.extent
        let angle = fake.double(scan.rotationDegrees) * fake.sign() * .pi / 180
        let rotation = CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .rotated(by: angle)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        let glass = CIImage(color: .white).cropped(to: extent)
        let adjusted = source.transformed(by: rotation)
            .composited(over: glass)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: scan.blurRadius)
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: scan.contrast,
                kCIInputBrightnessKey: scan.brightness,
                kCIInputSaturationKey: 0,
            ])
        var pixels = PixelBuffer(rendering: adjusted, bounds: extent, layout: .gray, context: context)
        pixels.addNoise(amplitude: scan.noiseAmplitude, fake: &fake)
        pixels.darkenLeftEdge(width: scan.edgeShadowWidth, depth: scan.edgeShadowDepth)
        pixels.addSpecks(count: fake.int(scan.dustSpecks), radius: scan.dustSpeckRadius, shade: scan.dustSpeckShade, fake: &fake)
        return pixels.cgImage
    }
}
