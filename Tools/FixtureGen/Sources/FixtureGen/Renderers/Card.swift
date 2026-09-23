import AppKit
import CoreText

/// A plastic card or passport data page, laid out in millimetres from its top-left corner.
struct Card: Sendable {
    let size: CGSize
    let cornerRadius: CGFloat
    /// Diagonal gradient stops (one stop = flat colour).
    let background: [RGB]
    /// Colour of the fine wavy security print; nil for none.
    let securityPrint: RGB?
    let elements: [CardElement]
}

enum CardElement: Sendable {
    /// Text whose top edge sits at `y`; `size` is the font size in millimetres.
    case text(String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, family: FontFamily = .sans, color: RGB = .ink)
    case box(CGRect, fill: RGB, radius: CGFloat = 0)
    /// Grey head-and-shoulders placeholder where the holder's photo would be.
    case portrait(CGRect)
    /// A seeded pen stroke.
    case signature(CGRect)
    /// Rotated overprint such as SPECIMEN.
    case stamp(String, centre: CGPoint, size: CGFloat, degrees: Double, color: RGB)
}

extension Card {
    var plainText: String {
        elements.compactMap { element in
            switch element {
            case .text(let text, _, _, _, _, _, _), .stamp(let text, _, _, _, _): text
            case .box, .portrait, .signature: nil
            }
        }.joined(separator: "\n")
    }
}

struct CardRenderer {
    let settings: RenderSettings

    /// The card alone on a transparent background, at `scale` pixels per millimetre.
    func image(_ card: Card, scale: CGFloat, fake: inout Fake) -> CGImage {
        let width = Int((card.size.width * scale).rounded())
        let height = Int((card.size.height * scale).rounded())
        let context = Raster.canvas(width: width, height: height, gray: false)
        draw(card, in: context, topLeft: .zero, scale: scale, canvasHeight: CGFloat(height), fake: &fake)
        return context.makeImage()!
    }

    /// Draws the card into a bitmap context whose origin is bottom-left; `topLeft` is measured from the top.
    func draw(_ card: Card, in context: CGContext, topLeft: CGPoint, scale: CGFloat, canvasHeight: CGFloat, fake: inout Fake) {
        context.saveGState()
        defer { context.restoreGState() }
        // Millimetres, y pointing down.
        context.translateBy(x: topLeft.x, y: canvasHeight - topLeft.y)
        context.scaleBy(x: scale, y: -scale)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let bounds = CGRect(origin: .zero, size: card.size)
        let outline = CGPath(roundedRect: bounds, cornerWidth: card.cornerRadius, cornerHeight: card.cornerRadius, transform: nil)
        context.addPath(outline)
        context.clip()
        drawBackground(card, bounds: bounds, in: context)
        if let ink = card.securityPrint {
            drawSecurityPrint(ink, bounds: bounds, in: context, fake: &fake)
        }
        for element in card.elements {
            drawElement(element, in: context, fake: &fake)
        }
        context.resetClip()
        context.addPath(outline)
        context.setStrokeColor(RGB.hairline.cgColor)
        context.setLineWidth(settings.cardArt.outlineWidth)
        context.strokePath()
    }

    private func drawBackground(_ card: Card, bounds: CGRect, in context: CGContext) {
        if card.background.count == 1 {
            context.setFillColor(card.background[0].cgColor)
            context.fill(bounds)
            return
        }
        let colours = card.background.map(\.cgColor) as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: nil) else {
            preconditionFailure("invalid card gradient")
        }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
    }

    /// Fine interleaved sine waves, like the guilloche print on ID documents.
    private func drawSecurityPrint(_ ink: RGB, bounds: CGRect, in context: CGContext, fake: inout Fake) {
        let art = settings.cardArt
        context.setStrokeColor(ink.cgColor(alpha: art.securityOpacity))
        context.setLineWidth(art.securityLineWidth)
        let phase = fake.double(0...(2 * .pi))
        let step = art.securityWavelength / 8
        var y = -art.securityLineSpacing
        while y < bounds.maxY + art.securityLineSpacing {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: y))
            var x: CGFloat = 0
            while x <= bounds.maxX {
                // Neighbouring lines drift in phase, which gives the interference look of guilloche print.
                path.addLine(to: CGPoint(x: x, y: y + art.securityWaveHeight * sin(x / art.securityWavelength + phase + y / art.securityWavelength)))
                x += step
            }
            context.addPath(path)
            y += art.securityLineSpacing
        }
        context.strokePath()
    }

    private func drawElement(_ element: CardElement, in context: CGContext, fake: inout Fake) {
        switch element {
        case .text(let text, let x, let y, let size, let bold, let family, let color):
            let font = Typeface.font(family, bold: bold, size: size, typography: settings.typography)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor(cgColor: color.cgColor)!, .ligature: 0,
            ]))
            context.textPosition = CGPoint(x: x, y: y + CTFontGetAscent(font))
            CTLineDraw(line, context)
        case .box(let rect, let fill, let radius):
            context.setFillColor(fill.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        case .portrait(let rect):
            context.saveGState()
            defer { context.restoreGState() }
            context.clip(to: rect)
            context.setFillColor(RGB(0.86, 0.87, 0.89).cgColor)
            context.fill(rect)
            context.setFillColor(RGB(0.58, 0.60, 0.64).cgColor)
            let head = CGRect(x: rect.midX - rect.width * 0.2, y: rect.minY + rect.height * 0.16,
                              width: rect.width * 0.4, height: rect.height * 0.42)
            context.fillEllipse(in: head)
            let shoulders = CGRect(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.62,
                                   width: rect.width * 0.84, height: rect.height * 0.7)
            context.fillEllipse(in: shoulders)
        case .signature(let rect):
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            let strokes = 5
            for index in 1...strokes {
                let x = rect.minX + rect.width * CGFloat(index) / CGFloat(strokes)
                let control1 = CGPoint(x: x - rect.width / CGFloat(strokes) * 0.7, y: rect.minY + rect.height * fake.double(0...0.4))
                let control2 = CGPoint(x: x - rect.width / CGFloat(strokes) * 0.3, y: rect.minY + rect.height * fake.double(0.6...1))
                path.addCurve(to: CGPoint(x: x, y: rect.minY + rect.height * fake.double(0.3...0.7)),
                              control1: control1, control2: control2)
            }
            context.setStrokeColor(RGB(0.10, 0.15, 0.45).cgColor)
            context.setLineWidth(settings.cardArt.penWidth)
            context.addPath(path)
            context.strokePath()
        case .stamp(let text, let centre, let size, let degrees, let color):
            let font = Typeface.font(.sans, bold: true, size: size, typography: settings.typography)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor(cgColor: color.cgColor)!, .ligature: 0,
            ]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.saveGState()
            context.translateBy(x: centre.x, y: centre.y)
            context.rotate(by: degrees * .pi / 180)
            context.textPosition = CGPoint(x: -width / 2, y: size * 0.35)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
