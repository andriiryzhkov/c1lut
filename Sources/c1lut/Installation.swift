import C1LUTCore
import Foundation

/// Where c1lut puts itself so Capture One's Scripts menu can use it:
///
///   <support>/bin/c1lut                                    this program
///   <support>/c1lut-export.scpt                            the worker that drives Capture One
///   ~/Library/Scripts/Capture One Scripts/Export Styles as LUTs.scpt   the menu entry
///
/// `C1LUT_SCRIPTS_DIR` overrides the Scripts folder, so installs can be tested in isolation.
struct Installation {
    let workspace: Workspace
    let scriptsDirectory: URL

    init(workspace: Workspace) {
        self.workspace = workspace
        if let custom = ProcessInfo.processInfo.environment["C1LUT_SCRIPTS_DIR"], !custom.isEmpty {
            scriptsDirectory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            scriptsDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Scripts/Capture One Scripts", isDirectory: true)
        }
    }

    var binary: URL { workspace.root.appendingPathComponent("bin/c1lut") }
    var worker: URL { workspace.root.appendingPathComponent("c1lut-export.scpt") }
    var launcher: URL { scriptsDirectory.appendingPathComponent("Export Styles as LUTs.scpt") }

    /// Copies this program into place and compiles the Capture One scripts against it.
    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)

        let running = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        if running.path != binary.resolvingSymlinksInPath().path {
            if fm.fileExists(atPath: binary.path) { try fm.removeItem(at: binary) }
            try fm.copyItem(at: running, to: binary)
        }

        try compile(PackageResources.worker_applescript, to: worker)
        try compile(PackageResources.launcher_applescript, to: launcher)
    }

    /// Removes everything `install` and later runs created. Exported LUTs and the Capture One
    /// session are the user's and stay.
    func uninstall() throws -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL
        let root = workspace.root.standardizedFileURL
        guard root.pathComponents.count > home.pathComponents.count, root != home else {
            throw CLIError(message: "refusing to remove \(root.path)")
        }
        var removed: [URL] = []
        for url in [launcher, root] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
            removed.append(url)
        }
        return removed
    }

    /// Fills in the installed paths and compiles an AppleScript with osacompile. Compiling needs
    /// Capture One's scripting dictionary, so it happens on the user's Mac, not at build time.
    private func compile(_ source: [UInt8], to destination: URL) throws {
        func literal(_ path: String) -> String {
            path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let text = String(decoding: source, as: UTF8.self)
            .replacingOccurrences(of: "@C1LUT@", with: literal(binary.path))
            .replacingOccurrences(of: "@WORKER@", with: literal(worker.path))
            .replacingOccurrences(of: "@PANASONIC_PAGE@", with: literal(PanasonicLUT.pageURL.absoluteString))

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("c1lut-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let sourceFile = work.appendingPathComponent("script.applescript")
        let compiled = work.appendingPathComponent("script.scpt")
        try Data(text.utf8).write(to: sourceFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", compiled.path, sourceFile.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(message: """
                could not compile \(destination.lastPathComponent). Capture One must be installed \
                for its Scripts menu to be set up.
                \(message.trimmingCharacters(in: .whitespacesAndNewlines))
                """)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: compiled, to: destination)
    }
}
