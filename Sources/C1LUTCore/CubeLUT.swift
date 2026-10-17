import Foundation

public typealias RGB = SIMD3<Double>

public enum CubeLUTError: Error, CustomStringConvertible {
    case missingSize
    case unsupported(String)
    case malformedLine(Int, String)
    case wrongEntryCount(expected: Int, found: Int)

    public var description: String {
        switch self {
        case .missingSize:
            return "not a 3D LUT: LUT_3D_SIZE is missing"
        case .unsupported(let what):
            return "unsupported .cube feature: \(what)"
        case .malformedLine(let number, let line):
            return "malformed line \(number): \(line)"
        case .wrongEntryCount(let expected, let found):
            return "expected \(expected) table entries, found \(found)"
        }
    }
}

/// A 3D LUT in the Adobe/Resolve `.cube` format.
///
/// Table order follows the format: red changes fastest, then green, then blue.
public struct CubeLUT: Equatable {
    public var title: String?
    public var size: Int
    public var domainMin: RGB
    public var domainMax: RGB
    public var table: [RGB]

    public init(size: Int, table: [RGB], title: String? = nil,
                domainMin: RGB = RGB(repeating: 0), domainMax: RGB = RGB(repeating: 1)) {
        precondition(size >= 2 && table.count == size * size * size, "table must hold size³ entries")
        self.size = size
        self.table = table
        self.title = title
        self.domainMin = domainMin
        self.domainMax = domainMax
    }

    public static func identity(size: Int) -> CubeLUT {
        var table: [RGB] = []
        table.reserveCapacity(size * size * size)
        let n = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    table.append(RGB(Double(r), Double(g), Double(b)) / n)
                }
            }
        }
        return CubeLUT(size: size, table: table)
    }

    public static func index(r: Int, g: Int, b: Int, size: Int) -> Int {
        r + g * size + b * size * size
    }

    public subscript(r: Int, g: Int, b: Int) -> RGB {
        get { table[Self.index(r: r, g: g, b: b, size: size)] }
        set { table[Self.index(r: r, g: g, b: b, size: size)] = newValue }
    }

    // MARK: Reading

    public static func load(contentsOf url: URL) throws -> CubeLUT {
        try parse(String(decoding: Data(contentsOf: url), as: UTF8.self))
    }

    public static func parse(_ text: String) throws -> CubeLUT {
        var title: String?
        var size: Int?
        var domainMin = RGB(repeating: 0)
        var domainMax = RGB(repeating: 1)
        var table: [RGB] = []

        var lineNumber = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            var line = Substring(rawLine)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            line = line.drop { $0 == "\u{FEFF}" }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let keyword = String(fields[0])

            if let first = keyword.first, first.isLetter {
                let args = fields.dropFirst().map(String.init)
                switch keyword {
                case "TITLE":
                    let rest = trimmed.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                    title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "LUT_3D_SIZE":
                    guard args.count == 1, let n = Int(args[0]), n >= 2, n <= 256 else {
                        throw CubeLUTError.malformedLine(lineNumber, trimmed)
                    }
                    size = n
                    table.reserveCapacity(n * n * n)
                case "DOMAIN_MIN", "DOMAIN_MAX":
                    guard args.count == 3, let v = triple(args) else {
                        throw CubeLUTError.malformedLine(lineNumber, trimmed)
                    }
                    if keyword == "DOMAIN_MIN" { domainMin = v } else { domainMax = v }
                case "LUT_3D_INPUT_RANGE":
                    guard args.count == 2, let lo = Double(args[0]), let hi = Double(args[1]) else {
                        throw CubeLUTError.malformedLine(lineNumber, trimmed)
                    }
                    domainMin = RGB(repeating: lo)
                    domainMax = RGB(repeating: hi)
                case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                    throw CubeLUTError.unsupported("1D LUTs and shaper LUTs (\(keyword))")
                default:
                    // Vendor keywords (e.g. LUT_IN_VIDEO_RANGE) don't change the table layout.
                    continue
                }
                continue
            }

            guard fields.count == 3, let v = triple(fields.map(String.init)) else {
                throw CubeLUTError.malformedLine(lineNumber, trimmed)
            }
            table.append(v)
        }

        guard let size else { throw CubeLUTError.missingSize }
        guard table.count == size * size * size else {
            throw CubeLUTError.wrongEntryCount(expected: size * size * size, found: table.count)
        }
        return CubeLUT(size: size, table: table, title: title, domainMin: domainMin, domainMax: domainMax)
    }

    private static func triple(_ s: [String]) -> RGB? {
        guard let a = Double(s[0]), let b = Double(s[1]), let c = Double(s[2]) else { return nil }
        return RGB(a, b, c)
    }

    // MARK: Writing

    /// Serializes the LUT. Output values are clamped to 0…1, which is what cameras expect.
    /// `comments` are written as `#` lines before the header.
    public func serialized(comments: [String] = []) -> String {
        var out = ""
        out.reserveCapacity(table.count * 28 + 256)
        for comment in comments {
            out += "# \(comment)\n"
        }
        if let title {
            out += "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"\n"
        }
        out += "LUT_3D_SIZE \(size)\n"
        if domainMin != RGB(repeating: 0) || domainMax != RGB(repeating: 1) {
            out += "DOMAIN_MIN \(Self.format(domainMin.x)) \(Self.format(domainMin.y)) \(Self.format(domainMin.z))\n"
            out += "DOMAIN_MAX \(Self.format(domainMax.x)) \(Self.format(domainMax.y)) \(Self.format(domainMax.z))\n"
        }
        out += "\n"
        for v in table {
            let c = v.clamped(lowerBound: RGB(repeating: 0), upperBound: RGB(repeating: 1))
            out += "\(Self.format(c.x)) \(Self.format(c.y)) \(Self.format(c.z))\n"
        }
        return out
    }

    public func write(to url: URL, comments: [String] = []) throws {
        try Data(serialized(comments: comments).utf8).write(to: url, options: .atomic)
    }

    static func format(_ v: Double) -> String {
        String(format: "%.6f", v)
    }

    // MARK: Sampling

    /// Looks up a color with tetrahedral interpolation. Inputs outside the domain are clamped.
    /// At lattice points the result is the table entry (up to floating-point rounding).
    public func sample(_ input: RGB) -> RGB {
        let n = size - 1
        let span = domainMax - domainMin
        var p = (input - domainMin) / span
        p.clamp(lowerBound: RGB(repeating: 0), upperBound: RGB(repeating: 1))
        p *= Double(n)

        let r0 = Swift.min(Int(p.x), n - 1), g0 = Swift.min(Int(p.y), n - 1), b0 = Swift.min(Int(p.z), n - 1)
        let fr = p.x - Double(r0), fg = p.y - Double(g0), fb = p.z - Double(b0)

        let c000 = self[r0, g0, b0]
        let c111 = self[r0 + 1, g0 + 1, b0 + 1]

        if fr > fg {
            if fg > fb {
                let c100 = self[r0 + 1, g0, b0], c110 = self[r0 + 1, g0 + 1, b0]
                return c000 + fr * (c100 - c000) + fg * (c110 - c100) + fb * (c111 - c110)
            } else if fr > fb {
                let c100 = self[r0 + 1, g0, b0], c101 = self[r0 + 1, g0, b0 + 1]
                return c000 + fr * (c100 - c000) + fb * (c101 - c100) + fg * (c111 - c101)
            } else {
                let c001 = self[r0, g0, b0 + 1], c101 = self[r0 + 1, g0, b0 + 1]
                return c000 + fb * (c001 - c000) + fr * (c101 - c001) + fg * (c111 - c101)
            }
        } else {
            if fb > fg {
                let c001 = self[r0, g0, b0 + 1], c011 = self[r0, g0 + 1, b0 + 1]
                return c000 + fb * (c001 - c000) + fg * (c011 - c001) + fr * (c111 - c011)
            } else if fb > fr {
                let c010 = self[r0, g0 + 1, b0], c011 = self[r0, g0 + 1, b0 + 1]
                return c000 + fg * (c010 - c000) + fb * (c011 - c010) + fr * (c111 - c011)
            } else {
                let c010 = self[r0, g0 + 1, b0], c110 = self[r0 + 1, g0 + 1, b0]
                return c000 + fg * (c010 - c000) + fr * (c110 - c010) + fb * (c111 - c110)
            }
        }
    }
}
