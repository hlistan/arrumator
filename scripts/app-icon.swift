// The app icon's generator, run by scripts/app-icon.sh: a sheet of paper arriving in an open tray, what the Incoming
// list stands for, drawn in the Incoming list's colour on a light plate. It writes every image macOS asks an app icon
// for into an AppIcon set, the same pixels on every run.
//
// The drawing is the project's own, made only of the paths below. It deliberately uses no SF Symbol, system glyph, font,
// emoji or third-party artwork: Apple's SF Symbols licence does not allow symbols, or glyphs substantially or
// confusingly similar to them, in an app icon, and an icon with one could not be distributed. Keep it that way: the
// icon gate in scripts/lint.sh fails on any of them.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
enum AppIconGenerator {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fail("usage: app-icon <Palette.swift> <folder to write AppIcon.appiconset into>") }
        let ink = Ink(incomingListIn: arguments[1])
        let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for image in IconImage.all {
                try render(pixels: image.pixels, ink: ink).write(to: folder.appendingPathComponent(image.filename))
            }
            try IconImage.contents.write(to: folder.appendingPathComponent("Contents.json"))
        } catch {
            fail("could not write the icon set into \(folder.path): \(error.localizedDescription)")
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("app-icon: \(message)\n".utf8))
    exit(1)
}

// MARK: The images an app icon set holds

/// One image of the set: every size macOS asks for, at 1x and 2x (Asset Catalog Format Reference › App Icon Type).
struct IconImage {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)\(scale == 1 ? "" : "@\(scale)x").png" }

    static let all = [16, 32, 128, 256, 512].flatMap { points in [1, 2].map { IconImage(points: points, scale: $0) } }

    /// The set's Contents.json, as Xcode writes it.
    static var contents: Data {
        let images = all.map {
            "    {\n      \"filename\" : \"\($0.filename)\",\n      \"idiom\" : \"mac\",\n      \"scale\" : \"\($0.scale)x\",\n"
                + "      \"size\" : \"\($0.points)x\($0.points)\"\n    }"
        }
        let json = "{\n  \"images\" : [\n" + images.joined(separator: ",\n")
            + "\n  ],\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
        return Data(json.utf8)
    }
}

// MARK: The Incoming list's colour

/// The colours the drawing is made of: the Incoming list's colour, read from where the app defines it, and the light
/// tints of it the drawing needs.
struct Ink {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    /// The SwiftUI colours `Palette` may give the Incoming list, as the AppKit system colours they are (Human Interface
    /// Guidelines › Color › Specifications). The icon takes the light appearance's value.
    private static let systemColours: [String: NSColor] = [
        "red": .systemRed, "orange": .systemOrange, "yellow": .systemYellow, "green": .systemGreen, "mint": .systemMint,
        "teal": .systemTeal, "cyan": .systemCyan, "blue": .systemBlue, "indigo": .systemIndigo, "purple": .systemPurple,
        "pink": .systemPink, "brown": .systemBrown, "gray": .systemGray,
    ]

    init(incomingListIn palette: String) {
        guard let source = try? String(contentsOfFile: palette, encoding: .utf8) else { fail("cannot read \(palette)") }
        let definition = /^\s*static let incomingList(?:: Color)? = (?:Color)?\.([A-Za-z]+)\s*$/.anchorsMatchLineEndings()
        guard let match = source.firstMatch(of: definition) else {
            fail("cannot find the Incoming list's colour in \(palette): expected `static let incomingList = Color.<name>`")
        }
        let name = String(match.1)
        guard let colour = Self.systemColours[name] else {
            fail("Palette.incomingList is Color.\(name), which the app icon does not know; it knows "
                + Self.systemColours.keys.sorted().joined(separator: ", "))
        }
        var resolved: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { resolved = colour.usingColorSpace(.sRGB) }
        guard let resolved else { fail("cannot resolve Color.\(name) in the sRGB colour space") }
        red = resolved.redComponent
        green = resolved.greenComponent
        blue = resolved.blueComponent
    }

    /// How much of the colour its light tint keeps, for the inside of the tray and the folded corner.
    private static let tintStrength: CGFloat = 0.45

    /// The colour itself.
    var full: NSColor { mixed(strength: 1) }
    /// The colour's light tint.
    var tint: NSColor { mixed(strength: Self.tintStrength) }

    /// The colour mixed with white: `strength` 1 is the colour, 0 is white.
    private func mixed(strength: CGFloat) -> NSColor {
        func mix(_ component: CGFloat) -> CGFloat { 1 - strength * (1 - component) }
        return NSColor(srgbRed: mix(red), green: mix(green), blue: mix(blue), alpha: 1)
    }
}

// MARK: The drawing

/// The canvas and the plate on it, in points of the 1024-point canvas the drawing is made on (origin at the bottom
/// left), as Apple's macOS app icon template has them (Apple Design Resources › macOS app icon template): an 824-point
/// square centred on the canvas, its corners rounded by 185.4 points with continuous curvature, which
/// `RoundedRectangle(style: .continuous)` draws. The margin around it lines the icon up with other apps' in the Dock.
enum Plate {
    static let canvas: CGFloat = 1024
    static let inset: CGFloat = 100
    static let cornerRadius: CGFloat = 185.4
    /// The plate's light fill, white at the top shading to this grey at the bottom.
    static let bottomWhite: CGFloat = 0.93
}

/// What the icon shows at one size. The small sizes are simpler drawings with thicker strokes, not the large one scaled
/// down, and their edges fall on whole pixels, so the page and the tray still read at 16 points.
struct Drawing {
    /// The tray's front, which hides the foot of the page.
    var front: CGRect
    var frontTopRadius: CGFloat
    var frontBottomRadius: CGFloat
    /// The inside of the tray, seen above its front: how high it shows (0 for not at all), and how much narrower its far
    /// edge is.
    var insideHeight: CGFloat
    var insideNarrowing: CGFloat
    /// The sheet of paper, its corners, its outline and its folded corner (0 for none).
    var page: CGRect
    var pageRadius: CGFloat
    var outline: CGFloat
    var fold: CGFloat
    /// The lines of text on the page: where they start, right of the page's left edge, how far each sits above the
    /// page's foot and how long it is, how thick they are, and whether their ends are round.
    var lineStart: CGFloat
    var lines: [(height: CGFloat, length: CGFloat)]
    var lineThickness: CGFloat
    var roundLines: Bool
    /// How dark the plate's edge is drawn, so a light plate keeps an edge on a light background.
    var edge: CGFloat

    static func at(pixels: Int) -> Drawing {
        switch pixels {
        case ...16: tiny
        case ...32: small
        default: large
        }
    }

    /// 16 pixels: every edge on the 64-point grid, one pixel at this size.
    static let tiny = Drawing(
        front: CGRect(x: 192, y: 192, width: 640, height: 192), frontTopRadius: 0, frontBottomRadius: 64,
        insideHeight: 0, insideNarrowing: 0,
        page: CGRect(x: 256, y: 320, width: 512, height: 512), pageRadius: 0, outline: 64, fold: 0,
        lineStart: 128, lines: [(height: 320, length: 256), (height: 192, length: 192)], lineThickness: 64, roundLines: false,
        edge: 0.2)

    /// 32 pixels: every edge on the 32-point grid, one pixel at this size.
    static let small = Drawing(
        front: CGRect(x: 224, y: 192, width: 576, height: 192), frontTopRadius: 0, frontBottomRadius: 64,
        insideHeight: 64, insideNarrowing: 32,
        page: CGRect(x: 320, y: 288, width: 384, height: 512), pageRadius: 32, outline: 64, fold: 0,
        lineStart: 96, lines: [(height: 320, length: 192), (height: 192, length: 128)], lineThickness: 64, roundLines: false,
        edge: 0.14)

    /// 64 pixels and more.
    static let large = Drawing(
        front: CGRect(x: 232, y: 211, width: 560, height: 182), frontTopRadius: 18, frontBottomRadius: 60,
        insideHeight: 60, insideNarrowing: 44,
        page: CGRect(x: 334, y: 313, width: 356, height: 500), pageRadius: 36, outline: 28, fold: 104,
        lineStart: 58, lines: [(height: 324, length: 236), (height: 250, length: 236), (height: 176, length: 160)],
        lineThickness: 30, roundLines: true, edge: 0.1)
}

func render(pixels: Int, ink: Ink) -> Data {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("cannot make a \(pixels)-pixel bitmap")
    }
    let scale = CGFloat(pixels) / Plate.canvas
    context.scaleBy(x: scale, y: scale)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(Drawing.at(pixels: pixels), ink: ink, pixel: 1 / scale)
    NSGraphicsContext.current = nil
    guard let image = context.makeImage() else { fail("cannot draw the \(pixels)-pixel image") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot encode PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot encode the \(pixels)-pixel image as PNG") }
    return data as Data
}

/// Draws the plate, the inside of the tray, the page in it and the tray's front over the page's foot. `pixel` is one
/// pixel in canvas points: the plate's edges land on whole pixels, so it stays sharp at every size.
func draw(_ drawing: Drawing, ink: Ink, pixel: CGFloat) {
    let inset = (Plate.inset / pixel).rounded() * pixel
    let plateRect = CGRect(x: inset, y: inset, width: Plate.canvas - 2 * inset, height: Plate.canvas - 2 * inset)
    let radius = Plate.cornerRadius * plateRect.width / (Plate.canvas - 2 * Plate.inset)
    let plate = NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: plateRect).cgPath)
    NSGradient(starting: NSColor(white: Plate.bottomWhite, alpha: 1), ending: .white)?.draw(in: plate, angle: 90)
    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSColor(white: 0, alpha: drawing.edge).setStroke()
    // Half the line falls outside the clip: the edge is one pixel wide, inside the plate.
    plate.lineWidth = 2 * pixel
    plate.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The inside of the tray: its far edge, narrower, above the front.
    let front = drawing.front
    let inside = NSBezierPath()
    inside.move(to: CGPoint(x: front.minX, y: front.maxY))
    inside.line(to: CGPoint(x: front.minX + drawing.insideNarrowing, y: front.maxY + drawing.insideHeight))
    inside.line(to: CGPoint(x: front.maxX - drawing.insideNarrowing, y: front.maxY + drawing.insideHeight))
    inside.line(to: CGPoint(x: front.maxX, y: front.maxY))
    inside.close()
    ink.tint.setFill()
    inside.fill()

    drawPage(drawing, ink: ink)

    ink.full.setFill()
    roundedRect(front, top: drawing.frontTopRadius, bottom: drawing.frontBottomRadius).fill()
}

/// The sheet of paper: white, outlined, with its lines of text and, when there is room, its top right corner folded.
func drawPage(_ drawing: Drawing, ink: Ink) {
    let page = drawing.page
    let half = drawing.outline / 2
    let edge = page.insetBy(dx: half, dy: half)
    let corner = max(drawing.pageRadius - half, 0)
    let fold = drawing.fold
    let sheet = NSBezierPath()
    sheet.move(to: CGPoint(x: edge.minX + corner, y: edge.minY))
    sheet.appendArc(from: CGPoint(x: edge.maxX, y: edge.minY), to: CGPoint(x: edge.maxX, y: edge.maxY), radius: corner)
    if fold > 0 {
        sheet.line(to: CGPoint(x: edge.maxX, y: edge.maxY - fold))
        sheet.line(to: CGPoint(x: edge.maxX - fold, y: edge.maxY))
    } else {
        sheet.appendArc(from: CGPoint(x: edge.maxX, y: edge.maxY), to: CGPoint(x: edge.minX, y: edge.maxY), radius: corner)
    }
    sheet.appendArc(from: CGPoint(x: edge.minX, y: edge.maxY), to: CGPoint(x: edge.minX, y: edge.minY), radius: corner)
    sheet.appendArc(from: CGPoint(x: edge.minX, y: edge.minY), to: CGPoint(x: edge.maxX, y: edge.minY), radius: corner)
    sheet.close()
    sheet.lineWidth = drawing.outline
    sheet.lineJoinStyle = .round
    NSColor.white.setFill()
    sheet.fill()
    ink.full.setStroke()
    sheet.stroke()

    if fold > 0 {
        let flap = NSBezierPath()
        flap.move(to: CGPoint(x: edge.maxX - fold, y: edge.maxY))
        flap.line(to: CGPoint(x: edge.maxX - fold, y: edge.maxY - fold))
        flap.line(to: CGPoint(x: edge.maxX, y: edge.maxY - fold))
        flap.close()
        flap.lineWidth = drawing.outline
        flap.lineJoinStyle = .round
        ink.tint.setFill()
        flap.fill()
        flap.stroke()
    }

    ink.full.setFill()
    let cap = drawing.roundLines ? drawing.lineThickness / 2 : 0
    for line in drawing.lines {
        let bar = CGRect(x: page.minX + drawing.lineStart, y: page.minY + line.height, width: line.length,
                         height: drawing.lineThickness)
        NSBezierPath(roundedRect: bar, xRadius: cap, yRadius: cap).fill()
    }
}

/// A rectangle with its top and bottom corners rounded by different radii.
func roundedRect(_ rect: CGRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.appendArc(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY), radius: bottom)
    path.appendArc(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY), radius: top)
    path.appendArc(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.minY), radius: top)
    path.appendArc(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY), radius: bottom)
    path.close()
    return path
}
