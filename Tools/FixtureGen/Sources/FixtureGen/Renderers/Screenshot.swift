import AppKit
import CoreText
import UniformTypeIdentifiers

/// A banking-app "payment details" screen as captured by the phone's screenshot function.
struct Screenshot: Sendable {
    /// Status-bar clock.
    let clock: String
    let navigationTitle: String
    let avatarInitials: String
    let amount: String
    let counterparty: String
    let status: String
    let rows: [Field]
    let actions: [String]
    let footnote: String
}

struct ScreenshotRenderer {
    let settings: RenderSettings

    func render(_ screen: Screenshot) -> Data {
        let style = settings.screenshot
        let width = Int(style.pointSize.width * style.scale)
        let height = Int(style.pointSize.height * style.scale)
        let context = Raster.canvas(width: width, height: height, gray: false)
        // Points, y pointing down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: style.scale, y: -style.scale)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let canvasWidth = style.pointSize.width

        context.setFillColor(style.background.cgColor)
        context.fill(CGRect(origin: .zero, size: style.pointSize))
        drawStatusBar(clock: screen.clock, in: context)

        // Navigation bar: back chevron and centred title.
        context.setStrokeColor(style.accent.cgColor)
        context.setLineWidth(2.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokeLineSegments(between: [CGPoint(x: 28, y: 64), CGPoint(x: 20, y: 72), CGPoint(x: 20, y: 72), CGPoint(x: 28, y: 80)])
        text(screen.navigationTitle, size: 17, bold: true, color: style.primaryText, x: canvasWidth / 2, top: 62, align: .center, in: context)

        // Counterparty avatar, amount, status: laid out top-down.
        var y: CGFloat = 104
        let avatar = CGRect(x: canvasWidth / 2 - 30, y: y, width: 60, height: 60)
        context.setFillColor(style.accent.cgColor(alpha: 0.14))
        context.fillEllipse(in: avatar)
        text(screen.avatarInitials, size: 23, bold: true, color: style.accent, x: canvasWidth / 2, top: y + 16, align: .center, in: context)
        y = avatar.maxY + 12
        text(screen.amount, size: 36, bold: true, color: style.primaryText, x: canvasWidth / 2, top: y, align: .center, in: context)
        y += 50
        text(screen.counterparty, size: 17, bold: false, color: style.secondaryText, x: canvasWidth / 2, top: y, align: .center, in: context)
        y += 32
        let pill = CGRect(x: canvasWidth / 2 - 60, y: y, width: 120, height: 28)
        context.setFillColor(style.success.cgColor(alpha: 0.14))
        context.addPath(CGPath(roundedRect: pill, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.fillPath()
        text(screen.status, size: 15, bold: true, color: style.success, x: canvasWidth / 2, top: y + 5, align: .center, in: context)
        y = pill.maxY + 22

        // Details card.
        let rowHeight: CGFloat = 44
        let card = CGRect(x: 16, y: y, width: canvasWidth - 32, height: rowHeight * CGFloat(screen.rows.count) + 8)
        context.setFillColor(style.card.cgColor)
        context.addPath(CGPath(roundedRect: card, cornerWidth: 16, cornerHeight: 16, transform: nil))
        context.fillPath()
        for (index, row) in screen.rows.enumerated() {
            let top = card.minY + 4 + CGFloat(index) * rowHeight
            text(row.label, size: 15, bold: false, color: style.secondaryText, x: card.minX + 16, top: top + 12, align: .left, in: context)
            text(row.value, size: 15, bold: false, color: style.primaryText, x: card.maxX - 16, top: top + 12, align: .right, in: context)
            if index < screen.rows.count - 1 {
                context.setFillColor(style.background.cgColor)
                context.fill(CGRect(x: card.minX + 16, y: top + rowHeight - 0.5, width: card.width - 32, height: 1))
            }
        }
        y = card.maxY + 18

        // Action buttons.
        let gap: CGFloat = 12
        let buttonWidth = (card.width - gap * CGFloat(screen.actions.count - 1)) / CGFloat(screen.actions.count)
        for (index, action) in screen.actions.enumerated() {
            let button = CGRect(x: card.minX + CGFloat(index) * (buttonWidth + gap), y: y, width: buttonWidth, height: 46)
            context.setFillColor(style.accent.cgColor(alpha: 0.12))
            context.addPath(CGPath(roundedRect: button, cornerWidth: 23, cornerHeight: 23, transform: nil))
            context.fillPath()
            text(action, size: 16, bold: true, color: style.accent, x: button.midX, top: button.minY + 13, align: .center, in: context)
        }
        y += 46 + 20
        text(screen.footnote, size: 13, bold: false, color: style.secondaryText, x: canvasWidth / 2, top: y, align: .center, in: context)
        y += 20
        precondition(y < style.pointSize.height - 24, "screenshot content does not fit above the home indicator")

        // Home indicator.
        context.setFillColor(style.primaryText.cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: canvasWidth / 2 - 67, y: style.pointSize.height - 13, width: 134, height: 5),
                               cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        context.fillPath()

        return Raster.encode(context.makeImage()!, as: .png)
    }

    private func drawStatusBar(clock: String, in context: CGContext) {
        let style = settings.screenshot
        let right = style.pointSize.width - 30
        text(clock, size: 17, bold: true, color: style.primaryText, x: 52, top: 16, align: .center, in: context)
        context.setFillColor(style.primaryText.cgColor)
        // Cellular bars.
        for bar in 0..<4 {
            let barHeight = 4 + CGFloat(bar) * 2.5
            context.fill(CGRect(x: right - 74 + CGFloat(bar) * 5, y: 31 - barHeight, width: 3, height: barHeight))
        }
        // Wi-Fi: three arcs above a dot.
        context.setStrokeColor(style.primaryText.cgColor)
        context.setLineWidth(1.8)
        for radius in [4.0, 8.0, 12.0] {
            context.addArc(center: CGPoint(x: right - 44, y: 32), radius: radius,
                           startAngle: -.pi * 3 / 4, endAngle: -.pi / 4, clockwise: false)
            context.strokePath()
        }
        // Battery.
        let battery = CGRect(x: right - 25, y: 20, width: 25, height: 12)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: battery, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        context.strokePath()
        context.fill(CGRect(x: battery.minX + 2, y: battery.minY + 2, width: 17, height: 8))
        context.fill(CGRect(x: battery.maxX + 1.5, y: battery.midY - 2, width: 1.5, height: 4))
    }

    private func text(_ string: String, size: CGFloat, bold: Bool, color: RGB, x: CGFloat, top: CGFloat,
                      align: TextAlignment, in context: CGContext) {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            .font: base, .foregroundColor: NSColor(cgColor: color.cgColor)!,
        ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let originX = switch align {
        case .left: x
        case .right: x - width
        case .center: x - width / 2
        }
        context.textPosition = CGPoint(x: originX, y: top + CTFontGetAscent(base))
        CTLineDraw(line, context)
    }
}
