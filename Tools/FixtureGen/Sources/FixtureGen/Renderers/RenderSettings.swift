import CoreGraphics

/// Every tunable rendering parameter of the corpus. Renderers never hard-code sizes, noise levels or qualities;
/// change the look of the corpus here and regenerate.
struct RenderSettings: Sendable {
    struct Page: Sendable {
        /// A4 in PostScript points.
        let size: CGSize
        let marginX: CGFloat
        let marginTop: CGFloat
        let marginBottom: CGFloat
        /// Height of the footer band (footer text and page label) above the bottom edge.
        let footerHeight: CGFloat
        var textWidth: CGFloat { size.width - 2 * marginX }
    }

    struct Typography: Sendable {
        let sansRegular: String
        let sansBold: String
        let serifRegular: String
        let serifBold: String
        let monoRegular: String
        let monoBold: String
        /// Body size of born-digital PDFs and DOCX files.
        let bodySize: CGFloat
        /// Body size of documents that are rasterised into scans; at 150 dpi this keeps OCR reliable.
        let scanBodySize: CGFloat
        let titleScale: CGFloat
        let subtitleScale: CGFloat
        let headingScale: CGFloat
        let noteScale: CGFloat
        let wordmarkScale: CGFloat
        let bannerScale: CGFloat
        let footerScale: CGFloat
        /// Extra leading between lines, as a fraction of the font size.
        let lineSpacing: CGFloat
        let spacing: Spacing
        /// Minimum and maximum start of the value column in label/value blocks, as fractions of the text width;
        /// within that range the column starts just after the longest label.
        let fieldLabelWidth: ClosedRange<CGFloat>
        /// Space between the longest label and the value column, in points.
        let fieldLabelGap: CGFloat
        /// Minimum space between table cells, in points.
        let tableCellGap: CGFloat
        /// Where the right column of two-column blocks starts, as a fraction of the text width.
        let columnSplit: CGFloat
        /// Font size of the invisible paragraph that carries a horizontal rule.
        let ruleCarrierSize: CGFloat
        let ruleLineWidth: CGFloat
        /// Padding around banner text, in points.
        let bannerPadding: CGFloat
    }

    /// Vertical space around blocks, as fractions of the body size.
    struct Spacing: Sendable {
        /// After a block that ends a visual group (fields, columns, wordmark) and before a banner.
        let block: CGFloat
        let paragraph: CGFloat
        let tagline: CGFloat
        let bannerAfter: CGFloat
        let titleBefore: CGFloat
        let titleAfter: CGFloat
        let subtitleAfter: CGFloat
        let headingBefore: CGFloat
        let headingAfter: CGFloat
        let noteBefore: CGFloat
        let noteAfter: CGFloat
        /// Between the lines of label/value blocks, two-column blocks and table rows.
        let fieldLine: CGFloat
        let columnLine: CGFloat
        let tableRow: CGFloat
        /// Height of the empty line closing a table.
        let tableTail: CGFloat
    }

    /// Card and ID-page artwork.
    struct CardArt: Sendable {
        /// Wavy security print: distance between lines, wave height and wavelength (millimetres).
        let securityLineSpacing: CGFloat
        let securityWaveHeight: CGFloat
        let securityWavelength: CGFloat
        let securityLineWidth: CGFloat
        let securityOpacity: Double
        let outlineWidth: CGFloat
        let penWidth: CGFloat
    }

    struct PDF: Sendable {
        /// Written to the Creator entry so nobody mistakes a fixture for a real document.
        let creator: String
        /// Hour of day used for the pinned CreationDate/ModDate (the date is the document's issue date).
        let metadataHour: Int
        let encryptionKeyLength: Int
        /// Share of the bytes of a valid PDF that survive in the truncated corrupt fixture.
        let truncatedFraction: Double
    }

    struct Scan: Sendable {
        let dpi: CGFloat
        /// Absolute skew of the page; the sign is seeded too.
        let rotationDegrees: ClosedRange<Double>
        /// Peak deviation of the triangular per-pixel noise, in 8-bit grey levels.
        let noiseAmplitude: Double
        let blurRadius: Double
        let contrast: Double
        let brightness: Double
        let jpegQuality: Double
        /// Darkening of the scanner-lid shadow along the left edge.
        let edgeShadowWidth: Int
        let edgeShadowDepth: Double
        let dustSpecks: ClosedRange<Int>
        let dustSpeckRadius: ClosedRange<Int>
        /// Grey level of a speck (0 = black).
        let dustSpeckShade: ClosedRange<Int>
        /// Where an ID page lies on the scanner glass, in millimetres from the top-left corner.
        let cardOriginMillimetres: CGPoint
        /// Days between the document date and the day it was scanned (the PDF creation date).
        let scanDelayDays: ClosedRange<Int>
    }

    struct Photo: Sendable {
        /// Pixel size of portrait photos (receipts) and landscape photos (cards).
        let portraitCanvas: CGSize
        let landscapeCanvas: CGSize
        /// Receipts are rendered at this monospace font size (pixels) before being photographed.
        let receiptFontSize: CGFloat
        let receiptLineHeight: CGFloat
        let receiptMargin: CGFloat
        let receiptQRModule: CGFloat
        /// Width of one tooth of the torn paper edge, in pixels.
        let receiptTearTooth: CGFloat
        let cardPixelsPerMillimetre: CGFloat
        /// Transparent border added around the subject before the perspective warp, in pixels.
        let subjectMargin: CGFloat
        /// Share of the canvas the subject occupies along its limiting axis.
        let subjectFill: Double
        /// Inward shift of the far edge, as a fraction of the subject width (perspective keystone).
        let keystone: ClosedRange<Double>
        /// Independent jitter of each corner, as a fraction of the subject size.
        let cornerJitter: Double
        let offsetJitter: Double
        let rotationDegrees: ClosedRange<Double>
        let shadowOpacity: Double
        let shadowRadius: Double
        let shadowOffset: CGSize
        let vignetteIntensity: Double
        let vignetteRadius: Double
        let blurRadius: Double
        let noiseAmplitude: Double
        let tableTop: RGB
        let tableBottom: RGB
        let paper: RGB
        let thermalInk: RGB
        let jpegQuality: Double
        let heicQuality: Double
        /// TIFF Software tag; marks the image as synthetic.
        let software: String
    }

    struct Screenshot: Sendable {
        /// iPhone-class screenshot: 393 × 852 points at 3×.
        let pointSize: CGSize
        let scale: CGFloat
        let background: RGB
        let card: RGB
        let primaryText: RGB
        let secondaryText: RGB
        let accent: RGB
        let success: RGB
    }

    struct Archive: Sendable {
        /// Modification time stamped on every ZIP entry (DOCX, XLSX), in UTC.
        let entryTimestamp: DateTimeStamp
    }

    struct Verification: Sendable {
        /// Resolution at which scanned PDF pages are rasterised for OCR (the app uses 200 dpi as well).
        let ocrDPI: CGFloat
        /// Share of `title_contains` entries OCR must recover from each scanned or photographed fixture.
        let minimumTitleCoverage: Double
    }

    let page: Page
    let typography: Typography
    let cardArt: CardArt
    let pdf: PDF
    let scan: Scan
    let photo: Photo
    let screenshot: Screenshot
    let archive: Archive
    let verification: Verification

    static let standard = RenderSettings(
        page: Page(
            size: CGSize(width: 595.28, height: 841.89),
            marginX: 50, marginTop: 46, marginBottom: 64, footerHeight: 44
        ),
        typography: Typography(
            sansRegular: "HelveticaNeue", sansBold: "HelveticaNeue-Bold",
            serifRegular: "TimesNewRomanPSMT", serifBold: "TimesNewRomanPS-BoldMT",
            monoRegular: "Menlo-Regular", monoBold: "Menlo-Bold",
            bodySize: 9.5, scanBodySize: 12,
            titleScale: 1.75, subtitleScale: 1.12, headingScale: 1.18, noteScale: 0.8,
            wordmarkScale: 2.7, bannerScale: 1.2, footerScale: 0.72,
            lineSpacing: 0.18,
            spacing: Spacing(
                block: 0.8, paragraph: 0.45, tagline: 0.1, bannerAfter: 0.6, titleBefore: 0.3, titleAfter: 0.5,
                subtitleAfter: 0.7, headingBefore: 0.9, headingAfter: 0.35, noteBefore: 0.2, noteAfter: 0.4,
                fieldLine: 0.18, columnLine: 0.12, tableRow: 0.22, tableTail: 0.6
            ),
            fieldLabelWidth: 0.3...0.6, fieldLabelGap: 12, tableCellGap: 4, columnSplit: 0.55,
            ruleCarrierSize: 5, ruleLineWidth: 0.6, bannerPadding: 4
        ),
        cardArt: CardArt(
            securityLineSpacing: 2.2, securityWaveHeight: 1.1, securityWavelength: 6, securityLineWidth: 0.12,
            securityOpacity: 0.35, outlineWidth: 0.25, penWidth: 0.35
        ),
        pdf: PDF(
            creator: "Arrumator FixtureGen (synthetic test document)",
            metadataHour: 9, encryptionKeyLength: 128, truncatedFraction: 0.4
        ),
        scan: Scan(
            dpi: 150, rotationDegrees: 0.6...1.2, noiseAmplitude: 14, blurRadius: 0.45,
            contrast: 0.9, brightness: -0.03, jpegQuality: 0.55,
            edgeShadowWidth: 26, edgeShadowDepth: 0.22,
            dustSpecks: 6...14, dustSpeckRadius: 1...2, dustSpeckShade: 40...110,
            cardOriginMillimetres: CGPoint(x: 18, y: 16), scanDelayDays: 2...9
        ),
        photo: Photo(
            portraitCanvas: CGSize(width: 1200, height: 1600),
            landscapeCanvas: CGSize(width: 1600, height: 1200),
            receiptFontSize: 24, receiptLineHeight: 31, receiptMargin: 28, receiptQRModule: 7, receiptTearTooth: 9,
            cardPixelsPerMillimetre: 14, subjectMargin: 16,
            subjectFill: 0.84, keystone: 0.025...0.05, cornerJitter: 0.008, offsetJitter: 0.025,
            rotationDegrees: 1.0...3.0,
            shadowOpacity: 0.45, shadowRadius: 14, shadowOffset: CGSize(width: 10, height: -14),
            vignetteIntensity: 0.55, vignetteRadius: 1.6, blurRadius: 0.7, noiseAmplitude: 9,
            tableTop: RGB(0.55, 0.42, 0.30), tableBottom: RGB(0.40, 0.29, 0.20),
            paper: RGB(0.97, 0.96, 0.93), thermalInk: RGB(0.16, 0.16, 0.18),
            jpegQuality: 0.72, heicQuality: 0.6,
            software: "Arrumator FixtureGen (synthetic test image)"
        ),
        screenshot: Screenshot(
            pointSize: CGSize(width: 393, height: 852), scale: 3,
            background: RGB(0.953, 0.957, 0.965), card: RGB(1, 1, 1),
            primaryText: RGB(0.07, 0.07, 0.09), secondaryText: RGB(0.45, 0.46, 0.50),
            accent: RGB(0.00, 0.40, 0.95), success: RGB(0.10, 0.62, 0.35)
        ),
        archive: Archive(entryTimestamp: DateTimeStamp(Day(2026, 1, 1), hour: 0, minute: 0, second: 0)),
        verification: Verification(ocrDPI: 200, minimumTitleCoverage: 0.6)
    )
}
