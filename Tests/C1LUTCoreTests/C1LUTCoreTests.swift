import Foundation
import Testing
@testable import C1LUTCore

// MARK: Helpers

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("c1lut-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A stand-in for Panasonic's V-Log → V-709 LUT: the published V-Log decoding followed by a
/// plain display gamma. Good enough to exercise the V-Log code paths.
func syntheticVLogBase(size: Int = 33) -> CubeLUT {
    func decode(_ v: Double) -> Double {
        v < 0.181 ? (v - 0.125) / 5.6 : pow(10, (v - 0.598206) / 0.241514) - 0.00873
    }
    var lut = CubeLUT.identity(size: size)
    lut.table = lut.table.map { v in
        RGB(pow(min(max(decode(v.x), 0), 1), 1 / 2.2),
            pow(min(max(decode(v.y), 0), 1), 1 / 2.2),
            pow(min(max(decode(v.z), 0), 1), 1 / 2.2))
    }
    lut.title = "synthetic V-Log to Rec.709"
    return lut
}

/// A made-up "style": a curve, a channel mix and a warm shift. Only per-pixel operations,
/// like the global color tools a LUT can capture.
func fakeStyle(_ c: RGB) -> RGB {
    let curved = RGB(pow(c.x, 0.9), pow(c.y, 1.0), pow(c.z, 1.15))
    let mixed = RGB(0.9 * curved.x + 0.1 * curved.y,
                    0.05 * curved.x + 0.9 * curved.y + 0.05 * curved.z,
                    0.1 * curved.y + 0.9 * curved.z)
    return (mixed + RGB(0.02, 0.0, -0.02)).clamped(lowerBound: RGB(repeating: 0), upperBound: RGB(repeating: 1))
}

func approxEqual(_ a: RGB, _ b: RGB, _ tolerance: Double) -> Bool {
    (a - b).max() <= tolerance && (b - a).max() <= tolerance
}

// MARK: .cube files

@Test func parsesHeaderCommentsAndDomain() throws {
    let text = "\u{FEFF}# comment\r\nTITLE \"My LUT\"\r\nLUT_3D_SIZE 2\r\nDOMAIN_MIN 0 0 0\r\nDOMAIN_MAX 1 1 1\r\nLUT_IN_VIDEO_RANGE\r\n"
        + "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1 # last\n"
    let lut = try CubeLUT.parse(text)
    #expect(lut.title == "My LUT")
    #expect(lut.size == 2)
    #expect(lut == { var id = CubeLUT.identity(size: 2); id.title = "My LUT"; return id }())
}

@Test func rejectsBrokenFiles() {
    #expect(throws: CubeLUTError.self) { try CubeLUT.parse("LUT_1D_SIZE 4\n0 0 0\n") }
    #expect(throws: CubeLUTError.self) { try CubeLUT.parse("0 0 0\n") }
    #expect(throws: CubeLUTError.self) { try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n") }
    #expect(throws: CubeLUTError.self) { try CubeLUT.parse("LUT_3D_SIZE 2\n0 0\n") }
}

@Test func serializationRoundTrips() throws {
    var lut = syntheticVLogBase(size: 9)
    lut.title = "Round \"trip\""
    let parsed = try CubeLUT.parse(lut.serialized(comments: ["hello"]))
    #expect(parsed.size == 9)
    #expect(parsed.title == "Round 'trip'")
    for (a, b) in zip(lut.table, parsed.table) {
        #expect(approxEqual(a, b, 1e-6))
    }
}

@Test func serializationClampsAndOmitsDefaultDomain() {
    var lut = CubeLUT.identity(size: 2)
    lut[1, 1, 1] = RGB(1.5, -0.2, 0.5)
    let text = lut.serialized()
    #expect(!text.contains("DOMAIN"))
    #expect(text.hasSuffix("1.000000 0.000000 0.500000\n"))
}

// MARK: Interpolation

@Test func samplingIsExactAtLatticePoints() {
    let lut = syntheticVLogBase(size: 17)
    for (r, g, b) in [(0, 0, 0), (16, 16, 16), (3, 9, 14), (16, 0, 7)] {
        let input = RGB(Double(r), Double(g), Double(b)) / 16
        #expect(approxEqual(lut.sample(input), lut[r, g, b], 1e-12))
    }
}

@Test func tetrahedralInterpolationReproducesLinearMaps() {
    // Tetrahedral interpolation is exact for affine functions, whatever the lattice size.
    func affine(_ c: RGB) -> RGB {
        RGB(0.2 + 0.5 * c.x + 0.1 * c.y, 0.3 * c.z + 0.6 * c.y, 0.9 * c.x - 0.2 * c.z + 0.2)
    }
    var lut = CubeLUT.identity(size: 5)
    lut.table = lut.table.map(affine)
    for p in [RGB(0.13, 0.77, 0.42), RGB(0.9, 0.1, 0.5), RGB(0.5, 0.5, 0.99), RGB(0.31, 0.62, 0.05)] {
        #expect(approxEqual(lut.sample(p), affine(p), 1e-12))
    }
    // Outside the domain the input is clamped.
    #expect(approxEqual(lut.sample(RGB(-1, 2, 0.5)), affine(RGB(0, 1, 0.5)), 1e-12))
}

// MARK: Grid

@Test func layoutSizes() {
    let lumix = GridLayout(size: 33)
    #expect(lumix.block == 8)
    #expect(lumix.tilesPerRow == 6)
    #expect(lumix.width == 1584 && lumix.height == 1584)
    let big = GridLayout(size: 65)
    #expect(big.block == 4)
    #expect(GridLayout.matching(width: big.width, height: big.height) == big)
    #expect(GridLayout.matching(width: 1584, height: 1584) == lumix)
    #expect(GridLayout.matching(width: 1584, height: 1583) == nil)
}

@Test func gridReadsBackItsOwnValues() throws {
    let layout = GridLayout(size: 17)
    let base = syntheticVLogBase()
    let reading = try Grid.read(Grid.makeImage(layout: layout, base: base))
    let expected = Grid.expectedValues(layout: layout, base: base)
    #expect(reading.lut.size == 17)
    #expect(reading.maxBlockSpread == 0)
    #expect(GridComparison(expected: expected, actual: reading.lut.table).maxDifference < 1e-6)
}

@Test func gridSurvivesA16BitTIFFRoundTrip() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let layout = GridLayout(size: 33)
    let url = dir.appendingPathComponent("grid.tif")
    try Grid.makeImage(layout: layout, base: syntheticVLogBase()).write(to: url)

    let image = try RGBImage.read(contentsOf: url)
    #expect(image.width == layout.width && image.height == layout.height)
    #expect(image.profileName?.localizedCaseInsensitiveContains("srgb") == true)
    let reading = try Grid.read(image)
    let expected = Grid.expectedValues(layout: layout, base: syntheticVLogBase())
    #expect(GridComparison(expected: expected, actual: reading.lut.table).maxDifference < 1e-6)
}

@Test func styledRenderBecomesTheStyleLUT() throws {
    // Simulates the whole pipeline with a per-pixel "style" standing in for Capture One.
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let base = syntheticVLogBase()
    let layout = GridLayout(size: 33)
    var render = Grid.makeImage(layout: layout, base: base)
    for i in 0..<(render.width * render.height) {
        render[pixel: i] = fakeStyle(render[pixel: i])
    }
    let url = dir.appendingPathComponent("render.tif")
    try render.write(to: url)

    let lut = try Grid.read(RGBImage.read(contentsOf: url)).lut
    // At lattice points: exactly base followed by the style (up to 16-bit storage).
    let identity = CubeLUT.identity(size: 33)
    for (input, out) in zip(identity.table, lut.table) {
        #expect(approxEqual(out, fakeStyle(base.sample(input)), 3.0 / 65535))
    }
    // Between lattice points: close to the real thing for V-Log input in the normal range.
    for p in [RGB(0.42, 0.40, 0.38), RGB(0.55, 0.35, 0.45), RGB(0.30, 0.50, 0.60)] {
        #expect(approxEqual(lut.sample(p), fakeStyle(base.sample(p)), 2.0 / 255))
    }
}

@Test func localAdjustmentsAreDetected() throws {
    let layout = GridLayout(size: 9)
    let image = Grid.makeImage(layout: layout, base: nil)
    // A wide box blur, like clarity or a large-radius sharpen, mixes neighbouring blocks.
    var blurred = image
    let radius = 3
    for y in 0..<image.height {
        for x in 0..<image.width {
            var sum = RGB(repeating: 0)
            var count = 0.0
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let sx = min(max(x + dx, 0), image.width - 1), sy = min(max(y + dy, 0), image.height - 1)
                    sum += image[sx, sy]
                    count += 1
                }
            }
            blurred[x, y] = sum / count
        }
    }
    #expect(try Grid.read(blurred).maxBlockSpread > 1.5 / 255)
    #expect(try Grid.read(image).maxBlockSpread == 0)
}

@Test func applyingAnIdentityLUTKeepsAnImage() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var image = RGBImage(width: 4, height: 2)
    image[0, 0] = RGB(0.1, 0.5, 0.9)
    image[3, 1] = RGB(1, 0, 0.25)
    let lut = CubeLUT.identity(size: 33)
    for i in 0..<(image.width * image.height) {
        image[pixel: i] = lut.sample(image[pixel: i])
    }
    let url = dir.appendingPathComponent("out.png")
    try image.write(to: url)
    let back = try RGBImage.read(contentsOf: url)
    #expect(approxEqual(back[0, 0], RGB(0.1, 0.5, 0.9), 1.0 / 65535))
    #expect(approxEqual(back[3, 1], RGB(1, 0, 0.25), 1.0 / 65535))
}

// MARK: Targets and naming

@Test func lumixNamesFitTheCamera() {
    let lumix = Target.named("lumix")!
    #expect(lumix.baseFileName(for: "My Look 2024 ✨") == "MYLOOK20")
    #expect(lumix.baseFileName(for: "Café crème") == "CAFECREM")
    #expect(lumix.baseFileName(for: "Портрет") == "PORTRET")
    #expect(lumix.baseFileName(for: "★★★") == "LUT")
    #expect(lumix.title(for: "Café \"crème\"") == "Cafe creme")
}

@Test func freeNamesOnlyLoseUnsafeCharacters() {
    let resolve = Target.named("REC709")!
    #expect(resolve.baseFileName(for: "Film / Warm: v2") == "Film - Warm- v2")
    #expect(resolve.baseFileName(for: "  ") == "LUT")
    #expect(resolve.baseFileName(for: ".hidden") == "LUT .hidden")
}

@Test func outputNamesAvoidOverwritingOtherStyles() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let lumix = Target.named("lumix")!
    var lut = CubeLUT.identity(size: 2)

    let first = lumix.outputURL(for: "Portrait Warm", in: dir)
    #expect(first.lastPathComponent == "PORTRAIT.cube")
    lut.title = lumix.title(for: "Portrait Warm")
    try lut.write(to: first)

    // Same style again: same file.
    #expect(lumix.outputURL(for: "Portrait Warm", in: dir) == first)
    // Different style, same short name: numbered file.
    #expect(lumix.outputURL(for: "Portrait Cool", in: dir).lastPathComponent == "PORTRAI2.cube")
}

// MARK: Workspace

@Test func workspaceCachesGridsAndNeedsABaseForVLog() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = Workspace(root: root)

    let rec709 = try workspace.grid(for: Target.named("rec709")!)
    #expect(FileManager.default.fileExists(atPath: rec709.path))
    #expect(try workspace.grid(for: Target.named("rec709")!) == rec709)
    #expect(rec709.lastPathComponent.hasPrefix("grid-rec709-33-"))

    #expect(throws: WorkspaceError.self) { try workspace.grid(for: Target.named("lumix")!) }

    let baseFile = root.appendingPathComponent("download.cube")
    try syntheticVLogBase().write(to: baseFile)
    let (_, warnings) = try workspace.installBaseLUT(from: baseFile, for: .vlog)
    #expect(warnings.isEmpty)
    let lumixGrid = try workspace.grid(for: Target.named("lumix")!)
    #expect(lumixGrid.lastPathComponent.hasPrefix("grid-vlog-33-"))
    #expect(lumixGrid.deletingLastPathComponent().lastPathComponent == lumixGrid.deletingPathExtension().lastPathComponent)
}

// MARK: Panasonic download

/// Zips `files` (name → .cube) the way Panasonic ships the LUT: inside a folder.
func makeZip(_ files: [String: CubeLUT], in dir: URL) throws -> URL {
    let folder = dir.appendingPathComponent("VLog_to_V709_forV35_ver100", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, lut) in files {
        try lut.write(to: folder.appendingPathComponent(name))
    }
    let zip = dir.appendingPathComponent("lut.zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
    try ditto.run()
    ditto.waitUntilExit()
    return zip
}

@Test func downloadedZipIsUnpackedAndInstalled() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let zip = try makeZip(["readme.cube": CubeLUT.identity(size: 2),
                           "VLog_to_V709_forV35_ver100.cube": syntheticVLogBase()], in: dir)

    let download = dir.appendingPathComponent("download", isDirectory: true)
    try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
    // A file:// URL stands in for Panasonic's server.
    let cube = try PanasonicLUT.fetchCube(from: zip, into: download)
    #expect(cube.lastPathComponent == "VLog_to_V709_forV35_ver100.cube")

    let workspace = Workspace(root: dir.appendingPathComponent("home"))
    #expect(!workspace.hasBaseLUT(for: .vlog))
    _ = try workspace.installBaseLUT(from: cube, for: .vlog, rejectSuspicious: true)
    #expect(workspace.hasBaseLUT(for: .vlog))
    #expect(workspace.hasBaseLUT(for: .rec709))
}

@Test func downloadsThatAreNotAVLogLUTAreRejected() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let workspace = Workspace(root: dir.appendingPathComponent("home"))

    let identity = dir.appendingPathComponent("identity.cube")
    try CubeLUT.identity(size: 17).write(to: identity)
    #expect(throws: WorkspaceError.self) {
        try workspace.installBaseLUT(from: identity, for: .vlog, rejectSuspicious: true)
    }
    #expect(!workspace.hasBaseLUT(for: .vlog))
    // Picked by hand, the same file is installed with warnings.
    #expect(try !workspace.installBaseLUT(from: identity, for: .vlog).1.isEmpty)

    let notZip = dir.appendingPathComponent("page.html")
    try Data("<html>moved</html>".utf8).write(to: notZip)
    #expect(throws: PanasonicLUT.DownloadError.self) {
        try PanasonicLUT.fetchCube(from: notZip, into: dir.appendingPathComponent("a"))
    }
    let emptyZip = try makeZip([:], in: dir.appendingPathComponent("b"))
    #expect(throws: PanasonicLUT.DownloadError.self) {
        try PanasonicLUT.fetchCube(from: emptyZip, into: dir.appendingPathComponent("c"))
    }
}

@Test func videoRangeBaseIsConvertedToFullRange() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // Like Panasonic's VARICAM V-709 LUT: the same conversion, written in video range.
    let full = syntheticVLogBase()
    var video = full
    video.table = full.table.map { ($0 * 876 + RGB(repeating: 64)) / 1023 }
    #expect(Workspace.hasVideoRangeOutput(video))
    #expect(!Workspace.hasVideoRangeOutput(full))

    let file = root.appendingPathComponent("video.cube")
    try video.write(to: file)
    let workspace = Workspace(root: root.appendingPathComponent("home"))
    _ = try workspace.installBaseLUT(from: file, for: .vlog, rejectSuspicious: true)
    let loaded = try #require(try workspace.loadBase(for: .vlog, override: nil))
    for (a, b) in zip(loaded.table, full.table) {
        #expect(approxEqual(a, b, 2e-6))
    }
}

@Test func baseSanityCheckFlagsNonVLogLUTs() {
    #expect(!Workspace.vlogSanityWarnings(CubeLUT.identity(size: 17)).isEmpty)
    #expect(Workspace.vlogSanityWarnings(syntheticVLogBase(size: 17)).isEmpty)
}
