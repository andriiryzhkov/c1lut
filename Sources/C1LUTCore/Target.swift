import Foundation

/// The color encoding a LUT expects as its input.
public enum InputSpace: String {
    /// Panasonic V-Log / V-Gamut. Needs a V-Log → Rec.709 base LUT to build the grid.
    case vlog
    /// Already display-ready Rec.709 / sRGB images. The grid is the plain identity.
    case rec709
}

/// Where a LUT is going to be used: its input encoding, lattice size and file naming rules.
public struct Target {
    public let id: String
    public let summary: String
    public let input: InputSpace
    public let size: Int
    /// Lumix cameras read names of up to 8 letters and digits from FAT32 cards.
    public let shortNames: Bool
    /// Some camera parsers are strict, so camera targets get a bare header without comments.
    public let writesComments: Bool

    public static let all: [Target] = [
        Target(id: "lumix",
               summary: "Lumix Real Time LUT (S5II and other Lumix cameras): V-Log in, Rec.709 out, 33-point, 8-character names",
               input: .vlog, size: 33, shortNames: true, writesComments: false),
        Target(id: "vlog",
               summary: "V-Log footage in grading apps such as DaVinci Resolve: V-Log in, Rec.709 out, 33-point",
               input: .vlog, size: 33, shortNames: false, writesComments: true),
        Target(id: "rec709",
               summary: "Rec.709 footage or timelines, e.g. in DaVinci Resolve: Rec.709 in and out, 33-point",
               input: .rec709, size: 33, shortNames: false, writesComments: true),
    ]

    public static func named(_ id: String) -> Target? {
        all.first { $0.id == id.lowercased() }
    }

    /// The title stored inside the `.cube`. Camera targets get plain ASCII only.
    public func title(for styleName: String) -> String {
        shortNames ? Self.ascii(styleName) : styleName.replacingOccurrences(of: "\"", with: "'")
    }

    /// File name (without extension) for a style's LUT.
    public func baseFileName(for styleName: String) -> String {
        if shortNames {
            let name = String(Self.ascii(styleName).uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
            return name.isEmpty ? "LUT" : name
        }
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = String(String.UnicodeScalarView(styleName.unicodeScalars.map { unsafe.contains($0) ? "-" : $0 }))
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return "LUT" }
        return cleaned.hasPrefix(".") ? "LUT \(cleaned)" : cleaned
    }

    /// Picks the output file for a style. Re-exporting the same style replaces its file;
    /// a different style whose name maps to the same file name gets a numbered one.
    public func outputURL(for styleName: String, in directory: URL) -> URL {
        let base = baseFileName(for: styleName)
        let title = title(for: styleName)
        for n in 1...999 {
            let name: String
            if n == 1 {
                name = base
            } else if shortNames {
                let suffix = String(n)
                name = String(base.prefix(8 - suffix.count)) + suffix
            } else {
                name = "\(base) \(n)"
            }
            let url = directory.appendingPathComponent(name).appendingPathExtension("cube")
            guard FileManager.default.fileExists(atPath: url.path) else { return url }
            if Self.storedTitle(of: url) == title { return url }
        }
        return directory.appendingPathComponent(base).appendingPathExtension("cube")
    }

    static func storedTitle(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
        for line in head.split(whereSeparator: \.isNewline) where line.hasPrefix("TITLE") {
            return line.dropFirst("TITLE".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    static func ascii(_ s: String) -> String {
        let latin = s.applyingTransform(.toLatin, reverse: false) ?? s
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return String(plain.filter { $0.isASCII && !$0.isNewline && $0 != "\"" })
            .trimmingCharacters(in: .whitespaces)
    }
}
