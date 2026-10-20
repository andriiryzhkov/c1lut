import Foundation

/// Files c1lut keeps between runs, under `~/Library/Application Support/c1lut`
/// (or `$C1LUT_HOME` when set, which the tests use).
public struct Workspace {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let custom = ProcessInfo.processInfo.environment["C1LUT_HOME"], !custom.isEmpty {
            self.root = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/c1lut", isDirectory: true)
        }
    }

    public var gridsDirectory: URL { root.appendingPathComponent("grids", isDirectory: true) }
    var baseDirectory: URL { root.appendingPathComponent("base", isDirectory: true) }

    public static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/c1lut", isDirectory: true)
    }

    /// The installed base conversion for an input space (V-Log → Rec.709), if one is needed.
    public func baseLUTURL(for input: InputSpace) -> URL? {
        switch input {
        case .vlog: return baseDirectory.appendingPathComponent("vlog-to-rec709.cube")
        case .rec709: return nil
        }
    }

    public func hasBaseLUT(for input: InputSpace) -> Bool {
        baseLUTURL(for: input).map { FileManager.default.fileExists(atPath: $0.path) } ?? true
    }

    /// Validates and installs a base LUT. Returns the installed location and any warnings.
    /// With `rejectSuspicious`, a file that fails the sanity checks isn't installed; that's for
    /// downloads, where nobody picked the file by hand.
    public func installBaseLUT(from source: URL, for input: InputSpace,
                               rejectSuspicious: Bool = false) throws -> (URL, [String]) {
        guard let destination = baseLUTURL(for: input) else {
            throw WorkspaceError.noBaseNeeded(input)
        }
        let lut = try CubeLUT.load(contentsOf: source)
        let warnings = input == .vlog ? Self.vlogSanityWarnings(lut) : []
        if rejectSuspicious && !warnings.isEmpty {
            throw WorkspaceError.suspiciousBase(warnings)
        }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return (destination, warnings)
    }

    /// Loose checks that a LUT really expects V-Log input and produces a display image.
    static func vlogSanityWarnings(_ lut: CubeLUT) -> [String] {
        // V-Log code values: 0.125 is black, 0.423 is 18% grey (Panasonic V-Log spec).
        let black = lut.sample(RGB(repeating: 0.125)).max()
        let grey = lut.sample(RGB(repeating: 0.423)).sum() / 3
        var warnings: [String] = []
        if black > 0.12 {
            warnings.append(String(format: "V-Log black maps to %.2f; a V-Log → Rec.709 LUT should make it close to 0. Is this the right file?", black))
        }
        if grey < 0.3 || grey > 0.6 {
            warnings.append(String(format: "V-Log 18%% grey maps to %.2f; a V-Log → Rec.709 LUT should put it near 0.4–0.5. Is this the right file?", grey))
        }
        return warnings
    }

    /// Whether a V-Log → Rec.709 LUT writes video-range output: V-Log black (10-bit code 128)
    /// lands on video black (code 64) instead of 0. Panasonic's VARICAM V-709 LUT does this.
    public static func hasVideoRangeOutput(_ vlogBase: CubeLUT) -> Bool {
        let black = vlogBase.sample(RGB(repeating: 128.0 / 1023)).sum() / 3
        return abs(black - 64.0 / 1023) < 0.02
    }

    /// Maps video-range output (codes 64…940 of 1023) to full range (0…1), as Lumix cameras
    /// and Capture One expect. Highlights above video white are clipped.
    static func fullRangeOutput(_ lut: CubeLUT) -> CubeLUT {
        var converted = lut
        converted.table = lut.table.map {
            (($0 * 1023 - RGB(repeating: 64)) / 876)
                .clamped(lowerBound: RGB(repeating: 0), upperBound: RGB(repeating: 1))
        }
        return converted
    }

    /// The base conversion for an input space, with its output in full range.
    public func loadBase(for input: InputSpace, override: URL?) throws -> CubeLUT? {
        let lut: CubeLUT
        if let override {
            lut = try CubeLUT.load(contentsOf: override)
        } else {
            guard let url = baseLUTURL(for: input) else { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WorkspaceError.missingBase(input)
            }
            lut = try CubeLUT.load(contentsOf: url)
        }
        return input == .vlog && Self.hasVideoRangeOutput(lut) ? Self.fullRangeOutput(lut) : lut
    }

    /// Returns the grid image for a target, creating it if needed. Each grid lives in its own
    /// folder (Capture One browses that folder) and its name changes whenever its content would.
    public func grid(for target: Target, size: Int? = nil, baseOverride: URL? = nil) throws -> URL {
        let layout = GridLayout(size: size ?? target.size)
        let base = try loadBase(for: target.input, override: baseOverride)
        let name = "grid-\(target.input.rawValue)-\(layout.size)-\(Self.fingerprint(layout: layout, base: base))"
        let folder = gridsDirectory.appendingPathComponent(name, isDirectory: true)
        let file = folder.appendingPathComponent(name).appendingPathExtension("tif")
        if FileManager.default.fileExists(atPath: file.path) { return file }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".\(name).partial.tif")
        try Grid.makeImage(layout: layout, base: base).write(to: partial)
        try FileManager.default.moveItem(at: partial, to: file)
        return file
    }

    /// The expected grid colors for a target, used to check Capture One's plain render.
    public func expectedGridValues(for target: Target, layout: GridLayout, baseOverride: URL? = nil) throws -> [RGB] {
        Grid.expectedValues(layout: layout, base: try loadBase(for: target.input, override: baseOverride))
    }

    /// FNV-1a over everything that determines the grid's pixels.
    static func fingerprint(layout: GridLayout, base: CubeLUT?) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            var v = value
            for _ in 0..<8 {
                hash ^= v & 0xff
                hash = hash &* 0x0000_0100_0000_01b3
                v >>= 8
            }
        }
        [1, layout.size, layout.block, layout.tilesPerRow].forEach { mix(UInt64($0)) }
        if let base {
            mix(UInt64(base.size))
            for v in base.table + [base.domainMin, base.domainMax] {
                mix(v.x.bitPattern); mix(v.y.bitPattern); mix(v.z.bitPattern)
            }
        }
        return String(String(hash, radix: 16).suffix(8))
    }
}

public enum WorkspaceError: Error, CustomStringConvertible {
    case missingBase(InputSpace)
    case noBaseNeeded(InputSpace)
    case suspiciousBase([String])

    public var description: String {
        switch self {
        case .missingBase:
            return """
            No V-Log → Rec.709 base LUT is installed. Run: c1lut setup --download-vlog-base \
            (or download Panasonic's V-Log to V-709 LUT from \(PanasonicLUT.pageURL.absoluteString) \
            and run: c1lut setup --vlog-base <file.cube>)
            """
        case .noBaseNeeded(let input):
            return "\(input.rawValue) input needs no base LUT"
        case .suspiciousBase(let warnings):
            return "the LUT doesn't look like a V-Log → Rec.709 conversion, so it wasn't installed. "
                + warnings.joined(separator: " ")
        }
    }
}
