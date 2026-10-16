import AppKit
import ArrumatorCore

/// An answer as rich text for the pasteboard (`AppModel.copy(answer:)`), made of the blocks the answer is shown by
/// (`AnswerMarkdown.blocks`): its emphasis as font traits, headings in bold, code in a fixed-width font, and lists with their
/// markers and indent. A link is inert here too: the blocks already hold its words and address as plain text.
enum RichAnswer {
    static func text(of markdown: String) -> NSAttributedString? {
        guard let blocks = AnswerMarkdown.blocks(markdown) else { return nil }
        let rich = NSMutableAttributedString()
        for (place, block) in blocks.enumerated() {
            if place > 0 { rich.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = Style.answerBlockSpacing
            var prefix = ""
            var bold = false
            var monospaced = false
            switch block.kind {
            case .heading:
                bold = true
            case let .item(marker):
                style.firstLineHeadIndent = CGFloat(block.depth) * Style.answerListIndent
                style.headIndent = CGFloat(block.depth + 1) * Style.answerListIndent
                prefix = marker.isEmpty ? "" : marker + " "
            case .quote:
                style.firstLineHeadIndent = Style.answerListIndent
                style.headIndent = Style.answerListIndent
            case .code:
                monospaced = true
            case .paragraph, .rule:
                break
            }
            let base = monospaced ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let line = NSMutableAttributedString(string: prefix, attributes: [.font: base, .paragraphStyle: style])
            for run in block.text.runs {
                var font = bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
                let intent = run.inlinePresentationIntent ?? []
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
                line.append(NSAttributedString(string: String(block.text[run.range].characters),
                                               attributes: [.font: font, .paragraphStyle: style]))
            }
            rich.append(line)
        }
        return rich
    }
}
