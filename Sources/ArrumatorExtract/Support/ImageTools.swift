import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageTools {
    /// The frame at `index` of `source`, orientation-corrected (EXIF) and scaled so the longest side is at most
    /// `maxPixel`. Decoding it takes time in proportion to the pixels it declares, so check `pixelSize(of:at:)` first.
    static func orientedImage(_ source: CGImageSource, at index: Int, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// The width and height the frame at `index` declares, read from its header without decoding it; `nil` when
    /// ImageIO finds none.
    static func pixelSize(of source: CGImageSource, at index: Int) -> (width: Int, height: Int)? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// JPEG encoding at `quality` (0…1).
    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// An 8-bit grayscale canvas filled with white, for rendering document pages before OCR.
    static func grayscaleCanvas(width: Int, height: Int) -> CGContext? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.setFillColor(gray: 1, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// Stretches contrast around mid-gray in place (`factor` 1 = unchanged), then snapshots the canvas.
    static func finishGrayscale(_ context: CGContext, contrast factor: Double) -> CGImage? {
        if factor != 1, let base = context.data {
            let lookup: [UInt8] = (0...255).map { value in
                let stretched = (Double(value) - 127.5) * factor + 127.5
                return UInt8(max(0, min(255, stretched.rounded())))
            }
            let pixels = base.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
            for row in 0..<context.height {
                let line = pixels + row * context.bytesPerRow
                for column in 0..<context.width {
                    line[column] = lookup[Int(line[column])]
                }
            }
        }
        return context.makeImage()
    }
}
