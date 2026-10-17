import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageError: Error, CustomStringConvertible {
    case cannotRead(URL)
    case cannotWrite(URL, String)

    public var description: String {
        switch self {
        case .cannotRead(let url): return "cannot read image \(url.path)"
        case .cannotWrite(let url, let why): return "cannot write image \(url.path): \(why)"
        }
    }
}

/// An RGB image with float components in 0…1, stored row by row as interleaved R, G, B.
public struct RGBImage {
    public let width: Int
    public let height: Int
    public var pixels: [Float]
    /// Description of the embedded ICC profile, when the image was read from a file.
    public var profileName: String?

    public init(width: Int, height: Int, fill: RGB = RGB(repeating: 0)) {
        self.width = width
        self.height = height
        pixels = [Float](repeating: 0, count: width * height * 3)
        if fill != RGB(repeating: 0) {
            for i in 0..<(width * height) { self[pixel: i] = fill }
        }
    }

    public subscript(pixel i: Int) -> RGB {
        get { RGB(Double(pixels[i * 3]), Double(pixels[i * 3 + 1]), Double(pixels[i * 3 + 2])) }
        set {
            pixels[i * 3] = Float(newValue.x)
            pixels[i * 3 + 1] = Float(newValue.y)
            pixels[i * 3 + 2] = Float(newValue.z)
        }
    }

    public subscript(x: Int, y: Int) -> RGB {
        get { self[pixel: y * width + x] }
        set { self[pixel: y * width + x] = newValue }
    }

    // MARK: Reading

    /// Reads any image ImageIO understands. Pixel values are taken as stored in the file's own
    /// color space: no color management is applied.
    public static func read(contentsOf url: URL) throws -> RGBImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageError.cannotRead(url)
        }
        return try RGBImage(cgImage: cgImage, url: url)
    }

    init(cgImage: CGImage, url: URL) throws {
        let w = cgImage.width, h = cgImage.height

        // Drawing into a context that shares the image's own RGB color space is a straight copy.
        // Images in any other color model are converted to sRGB.
        let sourceSpace = cgImage.colorSpace
        let space: CGColorSpace
        if let sourceSpace, sourceSpace.model == .rgb {
            space = sourceSpace
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }

        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        var rgba = [Float](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                                          bitsPerComponent: 32, bytesPerRow: w * 16,
                                          space: space, bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ImageError.cannotRead(url) }

        var rgb = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        width = w
        height = h
        pixels = rgb
        profileName = sourceSpace.flatMap(Self.describe)
    }

    static func describe(_ space: CGColorSpace) -> String? {
        if let name = space.name { return name as String }
        guard let icc = space.copyICCData() as Data? else { return nil }
        return ICCProfile.description(of: icc)
    }

    // MARK: Writing

    /// Writes the image tagged as sRGB. The format follows the file extension:
    /// `.tif`/`.tiff` and `.png` are 16-bit, `.jpg`/`.jpeg` is 8-bit.
    public func write(to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let type: UTType
        let bits: Int
        var properties: [CFString: Any] = [:]
        switch ext {
        case "tif", "tiff":
            type = .tiff
            bits = 16
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 1]
        case "png":
            type = .png
            bits = 16
        case "jpg", "jpeg":
            type = .jpeg
            bits = 8
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        default:
            throw ImageError.cannotWrite(url, "use .tif, .png or .jpg")
        }

        let cgImage = try makeCGImage(bitsPerComponent: bits)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageError.cannotWrite(url, "cannot create file")
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageError.cannotWrite(url, "encoding failed")
        }
    }

    func makeCGImage(bitsPerComponent bits: Int) throws -> CGImage {
        let count = width * height * 3
        let data: Data
        let bitmapInfo: CGBitmapInfo
        if bits == 16 {
            var words = [UInt16](repeating: 0, count: count)
            for i in 0..<count {
                words[i] = UInt16((min(max(pixels[i], 0), 1) * 65535).rounded()).littleEndian
            }
            data = words.withUnsafeBytes { Data($0) }
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        } else {
            var bytes = [UInt8](repeating: 0, count: count)
            for i in 0..<count {
                bytes[i] = UInt8((min(max(pixels[i], 0), 1) * 255).rounded())
            }
            data = Data(bytes)
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: bits,
                                  bitsPerPixel: bits * 3, bytesPerRow: width * bits * 3 / 8,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw ImageError.cannotWrite(URL(fileURLWithPath: "/"), "cannot create a \(bits)-bit image")
        }
        return image
    }
}

/// Minimal ICC header/tag reader, enough to show which profile an exported file carries.
enum ICCProfile {
    static func description(of data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 132 else { return nil }
        func u32(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        guard let tagCount = u32(128) else { return nil }
        for t in 0..<tagCount {
            let entry = 132 + t * 12
            guard let signature = u32(entry), let offset = u32(entry + 4), let size = u32(entry + 8) else { return nil }
            guard signature == 0x6465_7363 /* 'desc' */, offset + size <= bytes.count, size >= 12 else { continue }
            let tag = Array(bytes[offset..<(offset + size)])
            let type = String(decoding: tag[0..<4], as: UTF8.self)
            if type == "desc" {
                // ICC v2: ASCII description with a length prefix.
                let length = Int(tag[8]) << 24 | Int(tag[9]) << 16 | Int(tag[10]) << 8 | Int(tag[11])
                guard length > 0, 12 + length <= tag.count else { return nil }
                return String(decoding: tag[12..<(12 + length)], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            if type == "mluc", tag.count >= 28 {
                // ICC v4: first localized UTF-16BE record.
                let length = Int(tag[20]) << 24 | Int(tag[21]) << 16 | Int(tag[22]) << 8 | Int(tag[23])
                let start = Int(tag[24]) << 24 | Int(tag[25]) << 16 | Int(tag[26]) << 8 | Int(tag[27])
                guard start + length <= tag.count else { return nil }
                return String(bytes: tag[start..<(start + length)], encoding: .utf16BigEndian)
            }
        }
        return nil
    }
}
