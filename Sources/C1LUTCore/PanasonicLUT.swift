import Foundation

/// Panasonic's official V-Log → V-709 conversion LUT. c1lut doesn't redistribute it; it is
/// downloaded from Panasonic on the user's Mac, just as if they had clicked Download themselves.
public enum PanasonicLUT {
    /// The page offering the LUT, for people who download it by hand.
    public static let pageURL = URL(string: "https://eww.pass.panasonic.co.jp/pro-av/support/content/download/EN/ep2main/lut_e.htm")!
    /// The zip behind that page's Download button. It holds VLog_to_V709_forV35_ver100.cube.
    public static let downloadURL = URL(string: "https://eww.pass.panasonic.co.jp/pro-av/support/content/download/DEF/soft/VLog_to_V709_forV35_EN.zip")!

    public enum DownloadError: Error, CustomStringConvertible {
        case http(Int)
        case empty
        case unzipFailed
        case noCube

        public var description: String {
            switch self {
            case .http(let status): return "the server answered with HTTP status \(status)"
            case .empty: return "the download was empty"
            case .unzipFailed: return "the download is not a zip file"
            case .noCube: return "the zip contains no .cube file"
            }
        }
    }

    /// Downloads the zip into `directory` (which should be new and empty), unpacks it and returns
    /// the V-Log → V-709 `.cube` inside.
    public static func fetchCube(from url: URL = downloadURL, into directory: URL,
                                 timeout: TimeInterval = 60) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zip = directory.appendingPathComponent("download.zip")
        try download(url, to: zip, timeout: timeout)
        return try extractCube(fromZip: zip, into: directory.appendingPathComponent("unzipped", isDirectory: true))
    }

    static func download(_ url: URL, to file: URL, timeout: TimeInterval) throws {
        final class Outcome: @unchecked Sendable {
            var result: Result<Data, Error> = .failure(DownloadError.empty)
        }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: timeout)) { data, response, error in
            defer { done.signal() }
            if let error {
                outcome.result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                outcome.result = .failure(DownloadError.http(http.statusCode))
            } else if let data, !data.isEmpty {
                outcome.result = .success(data)
            }
        }.resume()
        done.wait()
        try outcome.result.get().write(to: file)
    }

    /// Unpacks a zip with the system's `ditto` and finds the conversion LUT in it.
    static func extractCube(fromZip zip: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, directory.path]
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw DownloadError.unzipFailed }

        var cubes: [URL] = []
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            if url.pathComponents.contains("__MACOSX") { continue }
            if url.pathExtension.lowercased() == "cube" { cubes.append(url) }
        }
        // Prefer the V-709 conversion if Panasonic ever ships more than one LUT in the zip.
        let cube = cubes.first { $0.lastPathComponent.contains("709") } ?? cubes.first
        guard let cube else { throw DownloadError.noCube }
        return cube
    }
}
