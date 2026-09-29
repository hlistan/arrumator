import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// An 8-bit pixel buffer (grey or RGBA) for the deterministic, seeded pixel effects that CoreImage cannot do
/// reproducibly (CIRandomGenerator has no seed).
struct PixelBuffer {
    enum Layout {
        case gray, rgba
        var channels: Int { self == .gray ? 1 : 4 }
    }

    let width: Int
    let height: Int
    let layout: Layout
    private(set) var bytes: [UInt8]

    init(rendering image: CIImage, bounds: CGRect, layout: Layout, context: CIContext) {
        width = Int(bounds.width)
        height = Int(bounds.height)
        self.layout = layout
        var storage = [UInt8](repeating: 0, count: width * height * layout.channels)
        let rowBytes = width * layout.channels
        storage.withUnsafeMutableBytes { raw in
            switch layout {
            case .gray:
                context.render(image, toBitmap: raw.baseAddress!, rowBytes: rowBytes, bounds: bounds,
                               format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            case .rgba:
                context.render(image, toBitmap: raw.baseAddress!, rowBytes: rowBytes, bounds: bounds,
                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
        }
        bytes = storage
    }

    /// Adds the same triangular luminance deviation to every colour channel of a pixel.
    mutating func addNoise(amplitude: Double, fake: inout Fake) {
        let channels = layout.channels
        let colourChannels = layout == .gray ? 1 : 3
        for pixel in 0..<(width * height) {
            let delta = fake.triangular() * amplitude
            for channel in 0..<colourChannels {
                let index = pixel * channels + channel
                bytes[index] = PixelBuffer.clamp(Double(bytes[index]) + delta)
            }
        }
    }

    /// Scanner-lid shadow: darkens a band along the left edge, strongest at the edge.
    mutating func darkenLeftEdge(width band: Int, depth: Double) {
        precondition(layout == .gray, "edge shadow is a scan effect")
        for x in 0..<min(band, width) {
            let falloff = 1 - Double(x) / Double(band)
            let factor = 1 - depth * falloff * falloff
            for y in 0..<height {
                let index = y * width + x
                bytes[index] = PixelBuffer.clamp(Double(bytes[index]) * factor)
            }
        }
    }

    /// Small dark dots from dust on the scanner glass.
    mutating func addSpecks(count: Int, radius: ClosedRange<Int>, shade: ClosedRange<Int>, fake: inout Fake) {
        precondition(layout == .gray, "specks are a scan effect")
        for _ in 0..<count {
            let centreX = fake.int(0...(width - 1))
            let centreY = fake.int(0...(height - 1))
            let r = fake.int(radius)
            let grey = UInt8(fake.int(shade))
            for y in max(0, centreY - r)...min(height - 1, centreY + r) {
                for x in max(0, centreX - r)...min(width - 1, centreX + r)
                where (x - centreX) * (x - centreX) + (y - centreY) * (y - centreY) <= r * r {
                    bytes[y * width + x] = min(bytes[y * width + x], grey)
                }
            }
        }
    }

    var cgImage: CGImage {
        let channels = layout.channels
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let space = layout == .gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = layout == .gray ? CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                                  bytesPerRow: width * channels, space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            preconditionFailure("could not wrap a \(width)×\(height) pixel buffer")
        }
        return image
    }

    private static func clamp(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }
}

enum Raster {
    /// CoreImage on the CPU: GPU kernels may differ in the last bit between runs and machines.
    static func makeContext() -> CIContext {
        CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    }

    /// Opaque bitmap context with a white background.
    static func canvas(width: Int, height: Int, gray: Bool) -> CGContext {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else {
            preconditionFailure("could not create a \(width)×\(height) bitmap context")
        }
        return context
    }

    /// Encodes one image with ImageIO. `quality` applies to lossy formats; `properties` carries EXIF/TIFF dictionaries.
    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil,
                       properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            preconditionFailure("ImageIO cannot write \(type.identifier) on this system")
        }
        var options = properties
        if let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            preconditionFailure("ImageIO failed to encode \(type.identifier)")
        }
        return data as Data
    }
}
