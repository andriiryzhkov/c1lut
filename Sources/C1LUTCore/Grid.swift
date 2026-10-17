import Foundation

/// Layout of the lattice ("identity grid") image that Capture One renders.
///
/// Every lattice point is a `block`×`block` square of one color. The 3D lattice is cut into
/// `size` tiles, one per blue level; inside a tile red runs left to right and green top to
/// bottom. Tiles are arranged in rows of `tilesPerRow`; spare tiles are filled with mid grey.
public struct GridLayout: Equatable {
    public let size: Int
    public let block: Int
    public let tilesPerRow: Int

    public init(size: Int) {
        precondition(size >= 2, "a 3D LUT needs at least 2 points per axis")
        self.size = size
        // Big blocks keep the sampled centre clear of any residual edge effects;
        // larger lattices use smaller blocks to keep the image a sensible size.
        block = size <= 33 ? 8 : 4
        tilesPerRow = Int(Double(size).squareRoot().rounded(.up))
    }

    public var tileSide: Int { size * block }
    public var rows: Int { (size + tilesPerRow - 1) / tilesPerRow }
    public var width: Int { tilesPerRow * tileSide }
    public var height: Int { rows * tileSide }

    /// Top-left pixel of the block for lattice point (r, g, b).
    public func origin(r: Int, g: Int, b: Int) -> (x: Int, y: Int) {
        let tileX = b % tilesPerRow, tileY = b / tilesPerRow
        return (tileX * tileSide + r * block, tileY * tileSide + g * block)
    }

    /// Pixels this far from a block's edge are ignored when reading it back.
    var sampleInset: Int { block / 4 }

    /// Finds the layout that produced an image of the given dimensions.
    public static func matching(width: Int, height: Int) -> GridLayout? {
        (2...129).lazy.map(GridLayout.init(size:)).first { $0.width == width && $0.height == height }
    }
}

public enum GridError: Error, CustomStringConvertible {
    case unexpectedDimensions(width: Int, height: Int)

    public var description: String {
        switch self {
        case .unexpectedDimensions(let w, let h):
            return "a \(w)×\(h) image is not a c1lut grid. Was it cropped, resized or rotated on export?"
        }
    }
}

/// What was read back from a rendered grid.
public struct GridReading {
    /// One entry per lattice point, in `.cube` order.
    public var lut: CubeLUT
    /// The largest per-channel difference between pixels inside any one sampled block.
    /// Near zero unless an adjustment mixed neighbouring pixels (sharpening, clarity, …).
    public var maxBlockSpread: Double
}

public enum Grid {
    static let padding = RGB(repeating: 0.5)

    /// The color each lattice point carries in the grid image: the base conversion applied to
    /// the lattice input, clamped to 0…1 and quantized to 16 bits as it is stored in the TIFF.
    public static func expectedValues(layout: GridLayout, base: CubeLUT?) -> [RGB] {
        let identity = CubeLUT.identity(size: layout.size)
        return identity.table.map { input in
            let out = (base?.sample(input) ?? input)
                .clamped(lowerBound: RGB(repeating: 0), upperBound: RGB(repeating: 1))
            return (out * 65535).rounded(.toNearestOrAwayFromZero) / 65535
        }
    }

    /// Builds the grid image. With a base LUT (e.g. V-Log → Rec.709) every block shows what
    /// the camera's input would look like after that conversion; without one it is the identity.
    public static func makeImage(layout: GridLayout, base: CubeLUT?) -> RGBImage {
        var image = RGBImage(width: layout.width, height: layout.height, fill: padding)
        let values = expectedValues(layout: layout, base: base)
        let n = layout.size
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let color = values[CubeLUT.index(r: r, g: g, b: b, size: n)]
                    let (x0, y0) = layout.origin(r: r, g: g, b: b)
                    for y in y0..<(y0 + layout.block) {
                        for x in x0..<(x0 + layout.block) {
                            image[x, y] = color
                        }
                    }
                }
            }
        }
        return image
    }

    /// Reads every lattice point back by averaging the centre of its block.
    public static func read(_ image: RGBImage) throws -> GridReading {
        guard let layout = GridLayout.matching(width: image.width, height: image.height) else {
            throw GridError.unexpectedDimensions(width: image.width, height: image.height)
        }
        let n = layout.size
        let inset = layout.sampleInset
        var table = [RGB](repeating: RGB(repeating: 0), count: n * n * n)
        var maxSpread = 0.0

        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let (x0, y0) = layout.origin(r: r, g: g, b: b)
                    var sum = RGB(repeating: 0)
                    var lo = RGB(repeating: .infinity), hi = RGB(repeating: -.infinity)
                    var count = 0.0
                    for y in (y0 + inset)..<(y0 + layout.block - inset) {
                        for x in (x0 + inset)..<(x0 + layout.block - inset) {
                            let p = image[x, y]
                            sum += p
                            lo = pointwiseMin(lo, p)
                            hi = pointwiseMax(hi, p)
                            count += 1
                        }
                    }
                    table[CubeLUT.index(r: r, g: g, b: b, size: n)] = sum / count
                    maxSpread = max(maxSpread, (hi - lo).max())
                }
            }
        }
        return GridReading(lut: CubeLUT(size: n, table: table), maxBlockSpread: maxSpread)
    }
}

/// How far a rendered grid is from the expected one, in 0…1 units.
public struct GridComparison {
    public var maxDifference: Double
    public var meanDifference: Double

    public init(expected: [RGB], actual: [RGB]) {
        precondition(expected.count == actual.count)
        var maxDiff = 0.0, total = 0.0
        for (e, a) in zip(expected, actual) {
            let d = abs(e - a)
            maxDiff = max(maxDiff, d.max())
            total += d.sum() / 3
        }
        maxDifference = maxDiff
        meanDifference = expected.isEmpty ? 0 : total / Double(expected.count)
    }
}

private func abs(_ v: RGB) -> RGB {
    RGB(Swift.abs(v.x), Swift.abs(v.y), Swift.abs(v.z))
}
