import Foundation

/// The color encoding a LUT expects as its input.
public enum InputSpace: String {
    /// Panasonic V-Log / V-Gamut. Needs a V-Log → Rec.709 base LUT to build the grid.
    case vlog
    /// Already display-ready Rec.709 / sRGB images. The grid is the plain identity.
    case rec709
}

/// How LUT files are named.
public enum FileNaming {
    /// Lumix on SDXC (exFAT) cards: letters and digits only, e.g. `STGoldenHour`.
    case lumixLong
    /// Lumix on SD/SDHC (FAT32) cards: at most 8 letters and digits, e.g. `STGOLDEN`.
    case lumixShort
    /// The style name, minus characters a file name can't hold.
    case styleName
}

/// Where a LUT is going to be used: its input encoding, lattice size and file naming rules.
public struct Target {
    public let id: String
    /// A short name for menus.
    public let title: String
    public let summary: String
    public let input: InputSpace
    public let size: Int
    public let naming: FileNaming
    /// The largest lattice the device accepts, if it has a limit.
    public let maxSize: Int?
    /// Some camera parsers are strict, so camera targets get a bare header without comments.
    public let writesComments: Bool

    public static let all: [Target] = [
        Target(id: "lumix", title: "Lumix camera, SDXC card (64 GB and larger)",
               summary: "Lumix Real Time LUT: V-Log in, Rec.709 out, 33-point, full style names",
               input: .vlog, size: 33, naming: .lumixLong, maxSize: 33, writesComments: false),
        Target(id: "lumix-sd", title: "Lumix camera, SD/SDHC card (32 GB and smaller)",
               summary: "Lumix Real Time LUT: V-Log in, Rec.709 out, 33-point, names cut to 8 characters",
               input: .vlog, size: 33, naming: .lumixShort, maxSize: 33, writesComments: false),
        Target(id: "vlog", title: "V-Log footage (DaVinci Resolve and others)",
               summary: "V-Log footage in grading apps such as DaVinci Resolve: V-Log in, Rec.709 out, 33-point",
               input: .vlog, size: 33, naming: .styleName, maxSize: nil, writesComments: true),
        Target(id: "rec709", title: "Rec.709 footage (DaVinci Resolve and others)",
               summary: "Rec.709 footage or timelines, e.g. in DaVinci Resolve: Rec.709 in and out, 33-point",
               input: .rec709, size: 33, naming: .styleName, maxSize: nil, writesComments: true),
    ]

    /// Lumix cameras accept letters and digits, up to 8 on FAT32 cards and 255 with the
    /// extension on exFAT cards.
    static let lumixLongLimit = 250, lumixShortLimit = 8

    var isCamera: Bool { naming != .styleName }

    public static func named(_ id: String) -> Target? {
        all.first { $0.id == id.lowercased() }
    }

    /// The title stored inside the `.cube`. Camera targets get plain ASCII only.
    public func title(for styleName: String) -> String {
        isCamera ? Self.ascii(styleName) : styleName.replacingOccurrences(of: "\"", with: "'")
    }

    /// File name (without extension) for a style's LUT.
    public func baseFileName(for styleName: String) -> String {
        let words = Self.ascii(styleName)
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .map(String.init)
        switch naming {
        case .lumixShort:
            let name = String(words.joined().uppercased().prefix(Self.lumixShortLimit))
            return name.isEmpty ? "LUT" : name
        case .lumixLong:
            // Each word starts with a capital so the name stays readable without spaces.
            let name = String(words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
                .prefix(Self.lumixLongLimit))
            return name.isEmpty ? "LUT" : name
        case .styleName:
            break
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
            let suffix = String(n)
            switch (n, naming) {
            case (1, _): name = base
            case (_, .lumixShort): name = String(base.prefix(Self.lumixShortLimit - suffix.count)) + suffix
            case (_, .lumixLong): name = String(base.prefix(Self.lumixLongLimit - suffix.count)) + suffix
            case (_, .styleName): name = "\(base) \(n)"
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
