import AppKit
import CoreText

extension NSAttributedString.Key {
    /// Marks a paragraph whose line gets a drawn decoration in PDFs (see `Decoration`).
    static let fixtureDecoration = NSAttributedString.Key("FixtureGenDecoration")
    /// Fill colour of a banner decoration.
    static let fixtureDecorationColor = NSAttributedString.Key("FixtureGenDecorationColor")
}

/// Drawn (not typed) elements of a PDF page.
enum Decoration: String {
    case rule, banner
}

enum Typeface {
    static func font(_ family: FontFamily, bold: Bool, size: CGFloat, typography: RenderSettings.Typography) -> NSFont {
        let name = switch (family, bold) {
        case (.sans, false): typography.sansRegular
        case (.sans, true): typography.sansBold
        case (.serif, false): typography.serifRegular
        case (.serif, true): typography.serifBold
        case (.mono, false): typography.monoRegular
        case (.mono, true): typography.monoBold
        }
        guard let font = NSFont(name: name, size: size) else {
            preconditionFailure("System font \(name) is missing; FixtureGen needs the standard macOS fonts")
        }
        return font
    }
}

/// Turns a `Document` into one attributed string. PDFs lay it out with CoreText; DOCX files are written by
/// AppKit's Office Open XML exporter from the same string, so both formats carry identical wording.
struct TextLayout {
    enum Target {
        /// Decorations are drawn by the PDF renderer; ligatures are disabled so extracted text stays plain.
        case pdf
        /// Decorations become plain styling (Word has no equivalent of the drawn band).
        case docx
    }

    let settings: RenderSettings
    let bodySize: CGFloat
    let target: Target

    private var typography: RenderSettings.Typography { settings.typography }
    private var spacing: RenderSettings.Spacing { settings.typography.spacing }
    private var width: CGFloat { settings.page.textWidth }

    func attributedString(for document: Document) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for block in document.blocks {
            output.append(render(block, in: document))
        }
        return output
    }

    // MARK: Blocks

    private func render(_ block: Block, in document: Document) -> NSAttributedString {
        let body = bodySize
        let family = document.family
        switch block {
        case .wordmark(let name, let tagline):
            let result = NSMutableAttributedString(attributedString: line(
                name, font: font(family, bold: true, size: body * typography.wordmarkScale), color: document.accent,
                style: style(after: body * (tagline == nil ? spacing.block : spacing.tagline))))
            if let tagline {
                result.append(line(tagline, font: font(family, size: body), color: .muted, style: style(after: body * spacing.block)))
            }
            return result
        case .banner(let text):
            let size = body * typography.bannerScale
            let padding = typography.bannerPadding
            let paragraph = style(before: body * spacing.block + padding, after: body * spacing.bannerAfter + padding, indent: padding)
            switch target {
            case .pdf:
                let result = NSMutableAttributedString(attributedString: line(
                    text, font: font(family, bold: true, size: size), color: .white, style: paragraph))
                result.addAttributes([.fixtureDecoration: Decoration.banner.rawValue,
                                      .fixtureDecorationColor: nsColor(document.accent)],
                                     range: NSRange(location: 0, length: result.length))
                return result
            case .docx:
                return line(text, font: font(family, bold: true, size: size), color: document.accent, style: paragraph)
            }
        case .title(let text, let alignment):
            return line(text, font: font(family, bold: true, size: body * typography.titleScale), color: .ink,
                        style: style(before: body * spacing.titleBefore, after: body * spacing.titleAfter, alignment: alignment))
        case .subtitle(let text, let alignment):
            return line(text, font: font(family, size: body * typography.subtitleScale), color: .ink,
                        style: style(after: body * spacing.subtitleAfter, alignment: alignment))
        case .heading(let text):
            return line(text, font: font(family, bold: true, size: body * typography.headingScale),
                        color: document.accent == .black ? .ink : document.accent,
                        style: style(before: body * spacing.headingBefore, after: body * spacing.headingAfter))
        case .paragraph(let text):
            return line(text, font: font(family, size: body), color: .ink,
                        style: style(after: body * spacing.paragraph, alignment: .left))
        case .strong(let text):
            return line(text, font: font(family, bold: true, size: body), color: .ink,
                        style: style(after: body * spacing.paragraph))
        case .note(let text):
            return line(text, font: font(family, size: body * typography.noteScale), color: .muted,
                        style: style(before: body * spacing.noteBefore, after: body * spacing.noteAfter))
        case .fields(let fields):
            return fieldBlock(fields, family: family)
        case .columns(let left, let right):
            return columnBlock(left: left, right: right, family: family)
        case .table(let table):
            return tableBlock(table, family: family)
        case .rule:
            return ruleLine()
        case .gap:
            return line("", font: font(family, size: body), color: .ink, style: style(after: 0))
        }
    }

    private func fieldBlock(_ fields: [Field], family: FontFamily) -> NSAttributedString {
        let longest = fields.map { measure($0.label, font: font(family, size: bodySize)) }.max() ?? 0
        let range = typography.fieldLabelWidth
        let tab = min(max(width * range.lowerBound, longest + typography.fieldLabelGap), width * range.upperBound)
        let paragraph = style(after: bodySize * spacing.fieldLine, tabs: [NSTextTab(textAlignment: .left, location: tab)], headIndent: tab)
        let result = NSMutableAttributedString()
        for (index, field) in fields.enumerated() {
            let isLast = index == fields.count - 1
            let lineStyle = isLast ? style(after: bodySize * spacing.block, tabs: paragraph.tabStops, headIndent: tab) : paragraph
            result.append(run(field.label + "\t", font: font(family, size: bodySize), color: .muted, style: lineStyle))
            result.append(run(field.value + "\n", font: font(family, size: bodySize), color: .ink, style: lineStyle))
        }
        return result
    }

    private func columnBlock(left: [String], right: [String], family: FontFamily) -> NSAttributedString {
        let tab = width * typography.columnSplit
        let result = NSMutableAttributedString()
        let count = max(left.count, right.count)
        for index in 0..<count {
            let isLast = index == count - 1
            let lineStyle = style(after: bodySize * (isLast ? spacing.block : spacing.columnLine),
                                  tabs: [NSTextTab(textAlignment: .left, location: tab)])
            let leftText = index < left.count ? left[index] : ""
            let rightText = index < right.count ? right[index] : ""
            let bold = index == 0
            result.append(run(leftText + "\t", font: font(family, bold: bold, size: bodySize), color: .ink, style: lineStyle))
            result.append(run(rightText + "\n", font: font(family, bold: bold, size: bodySize), color: .ink, style: lineStyle))
        }
        return result
    }

    private func tableBlock(_ table: Table, family: FontFamily) -> NSAttributedString {
        var tabs: [NSTextTab] = []
        var start: CGFloat = 0
        for (index, column) in table.columns.enumerated() {
            let columnWidth = width * column.width
            if index > 0 || column.alignment != .left {
                switch column.alignment {
                case .left: tabs.append(NSTextTab(textAlignment: .left, location: start))
                case .right: tabs.append(NSTextTab(textAlignment: .right, location: start + columnWidth - 2))
                case .center: tabs.append(NSTextTab(textAlignment: .center, location: start + columnWidth / 2))
                }
            }
            start += columnWidth
        }
        let rowStyle = style(after: bodySize * spacing.tableRow, tabs: tabs)
        let firstNeedsTab = table.columns[0].alignment != .left
        func row(_ cells: [String], bold: Bool) -> NSAttributedString {
            let cellFont = font(family, bold: bold, size: bodySize)
            for (cell, column) in zip(cells, table.columns) {
                let available = width * column.width - typography.tableCellGap
                precondition(measure(cell, font: cellFont) <= available,
                             "table cell \"\(cell)\" is wider than its \(Int(available)) pt column at \(bodySize) pt")
            }
            let text = (firstNeedsTab ? "\t" : "") + cells.joined(separator: "\t") + "\n"
            return run(text, font: cellFont, color: .ink, style: rowStyle)
        }
        let result = NSMutableAttributedString()
        result.append(row(table.columns.map(\.title), bold: true))
        result.append(ruleLine())
        for cells in table.rows {
            result.append(row(cells, bold: false))
        }
        if !table.totals.isEmpty {
            result.append(ruleLine())
            for cells in table.totals {
                result.append(row(cells, bold: true))
            }
        }
        result.append(line("", font: font(family, size: bodySize * spacing.tableTail), color: .ink, style: style(after: 0)))
        return result
    }

    private func ruleLine() -> NSAttributedString {
        switch target {
        case .pdf:
            let result = NSMutableAttributedString(attributedString: line(
                "", font: font(.sans, size: typography.ruleCarrierSize), color: .ink, style: style(after: 0)))
            result.addAttribute(.fixtureDecoration, value: Decoration.rule.rawValue,
                                range: NSRange(location: 0, length: result.length))
            return result
        case .docx:
            return line("", font: font(.sans, size: typography.ruleCarrierSize), color: .ink, style: style(after: 0))
        }
    }

    // MARK: Primitives

    private func line(_ text: String, font: NSFont, color: RGB, style: NSParagraphStyle) -> NSAttributedString {
        run(text + "\n", font: font, color: color, style: style)
    }

    private func run(_ text: String, font: NSFont, color: RGB, style: NSParagraphStyle) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: nsColor(color), .paragraphStyle: style]
        if target == .pdf {
            attributes[.ligature] = 0
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func measure(_ text: String, font: NSFont) -> CGFloat {
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])),
                                   nil, nil, nil)
    }

    private func font(_ family: FontFamily, bold: Bool = false, size: CGFloat) -> NSFont {
        Typeface.font(family, bold: bold, size: size, typography: typography)
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    private func style(before: CGFloat = 0, after: CGFloat, alignment: TextAlignment = .left,
                       tabs: [NSTextTab] = [], headIndent: CGFloat = 0, indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineSpacing = bodySize * typography.lineSpacing
        style.alignment = switch alignment {
        case .left: .natural
        case .right: .right
        case .center: .center
        }
        style.tabStops = tabs
        style.defaultTabInterval = 0
        style.headIndent = max(headIndent, indent)
        style.firstLineHeadIndent = indent
        style.tailIndent = indent > 0 ? -indent : 0
        return style
    }
}
