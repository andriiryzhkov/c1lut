import C1LUTCore
import Foundation

let usage = """
c1lut \(c1lutVersion) — Capture One styles → .cube LUTs for cameras and color grading

Usage:
  c1lut install
      Copy c1lut into ~/Library/Application Support/c1lut and add
      Scripts › Export Styles as LUTs to Capture One.
  c1lut uninstall
      Remove c1lut and its Scripts-menu entry. Exported LUTs stay.
  c1lut version
      Print the version.
  c1lut targets
      List LUT targets.
  c1lut setup --download-vlog-base [--if-missing]
      Download Panasonic's V-Log → V-709 LUT from Panasonic and install it as the starting
      point for V-Log targets. With --if-missing, keep one that is already installed.
  c1lut setup --vlog-base <file.cube>
      Install a V-Log → V-709 LUT you downloaded yourself.
  c1lut grid [--target <id>] [--size <n>] [--base <file.cube>]
      Create (once) the grid image Capture One renders, and print its path.
  c1lut check <render.tif> [--target <id>] [--base <file.cube>]
      Compare Capture One's render of the grid without a style to the grid itself.
  c1lut build <render.tif> --name <style> [--target <id>] [--out <dir>]
      Turn Capture One's render of the grid with a style into a .cube, and print its path.
  c1lut apply <lut.cube> <input-image> <output.tif|png|jpg>
      Apply a LUT to an image, e.g. a V-Log JPEG, to preview it.
  c1lut styles
      List the styles Capture One can export.
  c1lut export [--target <id>] <style> [<style> ...]
      Render styles in Capture One and build their LUTs (needs `c1lut install` and the
      session chosen once from Capture One's Scripts menu).
  c1lut path <render|output|support> [--target <id>]
      Print one of c1lut's folders.

The default target is "lumix". Output goes to ~/Documents/c1lut/<target>.
"""

struct CLIError: Error {
    var message: String
    var code: Int32 = 1
}

/// Exit codes the Capture One script relies on.
enum ExitCode {
    static let missingBase: Int32 = 3
    static let checkFailed: Int32 = 4
}

struct Arguments {
    /// Options that take no value.
    static let knownFlags: Set<String> = ["download-vlog-base", "if-missing"]

    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: ArraySlice<String>) throws {
        var it = args.makeIterator()
        while let arg = it.next() {
            if arg.hasPrefix("--"), Self.knownFlags.contains(String(arg.dropFirst(2))) {
                flags.insert(String(arg.dropFirst(2)))
            } else if arg.hasPrefix("--") {
                guard let value = it.next() else { throw CLIError(message: "\(arg) needs a value") }
                options[String(arg.dropFirst(2))] = value
            } else {
                positional.append(arg)
            }
        }
    }

    func url(_ key: String) -> URL? {
        options[key].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    func target() throws -> Target {
        let id = options["target"] ?? "lumix"
        guard let target = Target.named(id) else {
            throw CLIError(message: "unknown target \"\(id)\". Known targets: \(Target.all.map(\.id).joined(separator: ", "))")
        }
        return target
    }

    func file(at index: Int, _ what: String) throws -> URL {
        guard positional.count > index else { throw CLIError(message: "missing \(what)\n\n\(usage)") }
        return URL(fileURLWithPath: (positional[index] as NSString).expandingTildeInPath)
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

func eightBit(_ v: Double) -> String {
    String(format: "%.2f/255", v * 255)
}

func noteOutputRange(of base: URL) {
    guard let lut = try? CubeLUT.load(contentsOf: base), Workspace.hasVideoRangeOutput(lut) else { return }
    FileHandle.standardError.write(Data("""
        Its output is video range (black at 64). c1lut converts it to full range, which Lumix \
        cameras and Capture One expect.\n
        """.utf8))
}

/// Runs osascript with the terminal's input and output, and returns its exit status.
func osascript(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = arguments
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("c1lut: cannot run osascript: \(error)\n".utf8))
        return 1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

func run(_ argv: [String]) throws {
    guard let command = argv.dropFirst().first else {
        print(usage)
        return
    }
    let args = try Arguments(argv.dropFirst(2))
    let workspace = Workspace()

    switch command {
    case "install":
        let installation = Installation(workspace: workspace)
        try installation.install()
        print("""
            Installed c1lut \(c1lutVersion).
              Capture One: Scripts › Export Styles as LUTs
                (if it isn't there, choose Scripts › Update Scripts Menu or restart Capture One)
              Terminal:    "\(installation.binary.path)" help
            """)

    case "uninstall":
        for url in try Installation(workspace: workspace).uninstall() {
            print("Removed \(url.path)")
        }
        print("Your exported LUTs in \(Workspace.defaultOutputDirectory.path) and the c1lut Capture One session were kept.")

    case "version", "--version", "-v":
        print(c1lutVersion)

    case "targets":
        for target in Target.all {
            print("\(target.id)\t\(target.summary)")
        }

    case "setup" where args.flags.contains("download-vlog-base"):
        if args.flags.contains("if-missing") && workspace.hasBaseLUT(for: .vlog) {
            FileHandle.standardError.write(Data("Panasonic's V-Log to V-709 LUT is already installed.\n".utf8))
            return
        }
        // C1LUT_VLOG_BASE_URL points somewhere else, e.g. if Panasonic moves the file.
        let url = ProcessInfo.processInfo.environment["C1LUT_VLOG_BASE_URL"].flatMap(URL.init(string:))
            ?? PanasonicLUT.downloadURL
        FileHandle.standardError.write(Data("Downloading Panasonic's V-Log to V-709 LUT from \(url.host ?? url.absoluteString)…\n".utf8))
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("c1lut-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            let cube = try PanasonicLUT.fetchCube(from: url, into: work)
            let (installed, _) = try workspace.installBaseLUT(from: cube, for: .vlog, rejectSuspicious: true)
            FileHandle.standardError.write(Data("Installed Panasonic's V-Log to V-709 LUT.\n".utf8))
            noteOutputRange(of: installed)
            print(installed.path)
        } catch {
            let reason = (error as? PanasonicLUT.DownloadError)?.description
                ?? (error as? WorkspaceError)?.description
                ?? (error as? CubeLUTError)?.description
                ?? error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            throw CLIError(message: """
                could not download Panasonic's V-Log to V-709 LUT: \(reason). Download it from \
                \(PanasonicLUT.pageURL.absoluteString), unzip it and run: c1lut setup --vlog-base <file.cube>
                """)
        }

    case "setup":
        guard let source = args.url("vlog-base") else {
            throw CLIError(message: "usage: c1lut setup --download-vlog-base | --vlog-base <file.cube>")
        }
        let (installed, warnings) = try workspace.installBaseLUT(from: source, for: .vlog)
        warnings.forEach(warn)
        noteOutputRange(of: installed)
        print(installed.path)

    case "grid":
        let size = try args.options["size"].map { value -> Int in
            guard let n = Int(value), (2...65).contains(n) else { throw CLIError(message: "--size must be 2…65") }
            return n
        }
        do {
            print(try workspace.grid(for: try args.target(), size: size, baseOverride: args.url("base")).path)
        } catch let error as WorkspaceError {
            throw CLIError(message: error.description, code: ExitCode.missingBase)
        }

    case "check":
        let render = try RGBImage.read(contentsOf: try args.file(at: 0, "render file"))
        let reading = try Grid.read(render)
        let layout = GridLayout(size: reading.lut.size)
        let expected: [RGB]
        do {
            expected = try workspace.expectedGridValues(for: try args.target(), layout: layout, baseOverride: args.url("base"))
        } catch let error as WorkspaceError {
            throw CLIError(message: error.description, code: ExitCode.missingBase)
        }
        let comparison = GridComparison(expected: expected, actual: reading.lut.table)
        print("difference: max \(eightBit(comparison.maxDifference)), mean \(eightBit(comparison.meanDifference))")
        print("profile: \(render.profileName ?? "none")")
        // A render without adjustments should give back the grid. Allow for rounding only.
        if comparison.maxDifference > 2.0 / 255 || comparison.meanDifference > 0.5 / 255 {
            throw CLIError(message: """
                Capture One's render without a style differs from the grid \
                (max \(eightBit(comparison.maxDifference)), mean \(eightBit(comparison.meanDifference))). \
                LUTs would include that difference. Check that the c1lut recipe exports sRGB \
                and that no default adjustments are applied to TIFF files.
                """, code: ExitCode.checkFailed)
        }

    case "build":
        let target = try args.target()
        guard let name = args.options["name"], !name.isEmpty else {
            throw CLIError(message: "build needs --name <style name>")
        }
        let render = try RGBImage.read(contentsOf: try args.file(at: 0, "render file"))
        var reading = try Grid.read(render)
        if target.shortNames && reading.lut.size > 33 {
            throw CLIError(message: "\(target.id) LUTs can have at most 33 points; this grid has \(reading.lut.size)")
        }
        if reading.maxBlockSpread > 1.5 / 255 {
            warn("""
                neighbouring colors bled into each other (up to \(eightBit(reading.maxBlockSpread))). \
                A local adjustment such as sharpening, clarity or a layer is probably still active, \
                so the LUT may look noisy.
                """)
        }
        if let profile = render.profileName, !profile.localizedCaseInsensitiveContains("srgb") {
            warn("the render uses the ICC profile \"\(profile)\"; c1lut expects sRGB")
        }

        let outDir = args.url("out") ?? Workspace.defaultOutputDirectory.appendingPathComponent(target.id, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = target.outputURL(for: name, in: outDir)
        reading.lut.title = target.title(for: name)
        let comments = target.writesComments
            ? ["Created with c1lut from the Capture One style \"\(name)\"",
               "Input: \(target.input == .vlog ? "V-Log / V-Gamut" : "Rec.709"), output: Rec.709"]
            : []
        try reading.lut.write(to: url, comments: comments)
        print(url.path)

    case "apply":
        let lut = try CubeLUT.load(contentsOf: try args.file(at: 0, "LUT file"))
        var image = try RGBImage.read(contentsOf: try args.file(at: 1, "input image"))
        let output = try args.file(at: 2, "output image")
        for i in 0..<(image.width * image.height) {
            image[pixel: i] = lut.sample(image[pixel: i])
        }
        try image.write(to: output)
        print(output.path)

    case "styles":
        let status = osascript([
            "-e", "tell application \"Capture One\" to set styleNames to available styles",
            "-e", "set AppleScript's text item delimiters to linefeed",
            "-e", "styleNames as text",
        ])
        if status != 0 { throw CLIError(message: "could not ask Capture One for its styles", code: status) }

    case "export":
        let target = try args.target()
        guard !args.positional.isEmpty else {
            throw CLIError(message: "usage: c1lut export [--target <id>] <style> [<style> ...]")
        }
        let worker = Installation(workspace: workspace).worker
        guard FileManager.default.fileExists(atPath: worker.path) else {
            throw CLIError(message: "the Capture One worker script is missing; run `c1lut install` first")
        }
        let status = osascript([worker.path, "cli", target.id] + args.positional)
        if status != 0 { exit(status) }

    case "path":
        switch args.positional.first {
        case "render": print(workspace.renderDirectory.path)
        case "support": print(workspace.root.path)
        case "output": print(Workspace.defaultOutputDirectory.appendingPathComponent(try args.target().id).path)
        default: throw CLIError(message: "usage: c1lut path <render|output|support> [--target <id>]")
        }

    case "help", "-h", "--help":
        print(usage)

    default:
        throw CLIError(message: "unknown command \"\(command)\"\n\n\(usage)")
    }
}

do {
    try run(CommandLine.arguments)
} catch let error as CLIError {
    FileHandle.standardError.write(Data("c1lut: \(error.message)\n".utf8))
    exit(error.code)
} catch {
    FileHandle.standardError.write(Data("c1lut: \(error)\n".utf8))
    exit(1)
}
