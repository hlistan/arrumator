import AppKit
import CoreText

/// Born-digital PDF: CoreText lays out the document into an A4 `CGPDFContext`, so the file carries a real
/// text layer with embedded font subsets.
struct PDFTextRenderer {
    let settings: RenderSettings

    /// - Parameters:
    ///   - bodySize: body font size; scans pass the larger scan size.
    ///   - key: stable name used to derive the pinned document ID.
    ///   - password: user password; encrypted output cannot be pinned (the cipher salts every run).
    func render(_ document: Document, bodySize: CGFloat? = nil, key: String, password: String? = nil) -> Data {
        let layout = TextLayout(settings: settings, bodySize: bodySize ?? settings.typography.bodySize, target: .pdf)
        let text = layout.attributedString(for: document)
        let page = settings.page
        let frameRect = CGRect(x: page.marginX, y: page.marginBottom, width: page.textWidth,
                               height: page.size.height - page.marginTop - page.marginBottom)
        let frames = paginate(text, in: frameRect)

        var info: [CFString: Any] = [
            kCGPDFContextTitle: document.info.title,
            kCGPDFContextAuthor: document.info.author,
            kCGPDFContextSubject: document.info.subject,
            kCGPDFContextCreator: settings.pdf.creator,
        ]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
            info[kCGPDFContextEncryptionKeyLength] = settings.pdf.encryptionKeyLength
        }
        let data = PDFCanvas.draw(pageSize: page.size, info: info, pageCount: frames.count) { context, index in
            context.textMatrix = .identity
            drawDecorations(of: frames[index], text: text, origin: frameRect.origin, width: frameRect.width, in: context)
            CTFrameDraw(frames[index], context)
            drawFooter(document, page: index + 1, of: frames.count, bodySize: layout.bodySize, in: context)
        }
        return password == nil ? PDFIdentity.pin(data, created: document.info.created, hour: settings.pdf.metadataHour, key: key) : data
    }

    private func paginate(_ text: NSAttributedString, in rect: CGRect) -> [CTFrame] {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var frames: [CTFrame] = []
        var location = 0
        repeat {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0),
                                                 CGPath(rect: rect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            precondition(visible.length > 0, "a paragraph does not fit on an empty page")
            frames.append(frame)
            location += visible.length
        } while location < text.length
        return frames
    }

    /// Draws banner fills and horizontal rules for lines that carry a decoration attribute.
    private func drawDecorations(of frame: CTFrame, text: NSAttributedString, origin: CGPoint, width: CGFloat,
                                 in context: CGContext) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, lineOrigin) in zip(lines, origins) {
            let range = CTLineGetStringRange(line)
            guard range.length > 0,
                  let raw = text.attribute(.fixtureDecoration, at: range.location, effectiveRange: nil) as? String,
                  let decoration = Decoration(rawValue: raw) else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let baseline = origin.y + lineOrigin.y
            switch decoration {
            case .rule:
                context.setStrokeColor(RGB.hairline.cgColor)
                context.setLineWidth(settings.typography.ruleLineWidth)
                let y = baseline + (ascent - descent) / 2
                context.strokeLineSegments(between: [CGPoint(x: origin.x, y: y), CGPoint(x: origin.x + width, y: y)])
            case .banner:
                guard let color = text.attribute(.fixtureDecorationColor, at: range.location,
                                                 effectiveRange: nil) as? NSColor else { continue }
                let padding = settings.typography.bannerPadding
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: origin.x, y: baseline - descent - padding,
                                    width: width, height: ascent + descent + 2 * padding))
            }
        }
    }

    private func drawFooter(_ document: Document, page: Int, of total: Int, bodySize: CGFloat, in context: CGContext) {
        let pageSettings = settings.page
        let size = bodySize * settings.typography.footerScale
        let font = Typeface.font(document.family, bold: false, size: size, typography: settings.typography)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.gray, .ligature: 0]
        var labelWidth: CGFloat = 0
        if let language = document.pageNumbers {
            let label = CTLineCreateWithAttributedString(NSAttributedString(
                string: language.pageLabel(page, of: total), attributes: attributes))
            labelWidth = CTLineGetTypographicBounds(label, nil, nil, nil)
            context.textPosition = CGPoint(x: pageSettings.size.width - pageSettings.marginX - labelWidth,
                                           y: pageSettings.footerHeight - size * 1.5)
            CTLineDraw(label, context)
        }
        if let footer = document.footer {
            let rect = CGRect(x: pageSettings.marginX, y: 0,
                              width: pageSettings.textWidth - labelWidth - (labelWidth > 0 ? size * 2 : 0),
                              height: pageSettings.footerHeight)
            let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: footer, attributes: attributes))
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: rect, transform: nil), nil), context)
        }
    }
}

/// Opens a PDF context over memory and runs `drawPage` for every page.
enum PDFCanvas {
    static func draw(pageSize: CGSize, info: [CFString: Any], pageCount: Int,
                     drawPage: (CGContext, Int) -> Void) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            preconditionFailure("CoreGraphics refused to open a PDF context")
        }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            drawPage(context, index)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

/// Quartz stamps the wall-clock time into CreationDate/ModDate and derives the trailer `/ID` from it. Both are
/// overwritten in place with same-length values (the document date and a hash of the fixture name), so the
/// cross-reference offsets stay valid and the output is byte-for-byte reproducible.
enum PDFIdentity {
    static func pin(_ data: Data, created: Day, hour: Int, key: String) -> Data {
        var bytes = [UInt8](data)
        let stamp = Array(String(format: "%04d%02d%02d%02d0000", created.year, created.month, created.day, hour).utf8)
        let dateMarker = Array("(D:".utf8)
        var searchStart = 0
        while let found = firstIndex(of: dateMarker, in: bytes, from: searchStart) {
            let start = found + dateMarker.count
            if start + stamp.count <= bytes.count, bytes[start..<(start + stamp.count)].allSatisfy(isDigit) {
                bytes.replaceSubrange(start..<(start + stamp.count), with: stamp)
            }
            searchStart = start
        }
        let idMarker = Array("/ID [".utf8)
        if let found = firstIndex(of: idMarker, in: bytes, from: 0) {
            var fake = Fake(seed: 0, salt: "pdf-id:" + key)
            let identifier = Array(fake.hex(32).utf8)
            var cursor = found + idMarker.count
            for _ in 0..<2 {
                guard let open = bytes[cursor...].firstIndex(of: UInt8(ascii: "<")),
                      let close = bytes[open...].firstIndex(of: UInt8(ascii: ">")),
                      close - open - 1 == identifier.count else { break }
                bytes.replaceSubrange((open + 1)..<close, with: identifier)
                cursor = close + 1
            }
        }
        return Data(bytes)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard pattern.count <= bytes.count, start <= bytes.count - pattern.count else { return nil }
        var index = start
        while index <= bytes.count - pattern.count {
            if bytes[index] == pattern[0] && Array(bytes[index..<(index + pattern.count)]) == pattern {
                return index
            }
            index += 1
        }
        return nil
    }
}
