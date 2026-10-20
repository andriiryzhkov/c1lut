import Foundation

/// A folder or a style in Capture One's styles tree, with the selection state the picker shows.
public final class StyleNode {
    public enum CheckState { case off, on, mixed }

    public let name: String
    public let isFolder: Bool
    /// A style Capture One can't apply because an earlier style has the same name.
    public let isDuplicate: Bool
    public private(set) var children: [StyleNode] = []
    public private(set) weak var parent: StyleNode?
    private var checked = false
    private var foldersByName: [String: StyleNode] = [:]

    init(name: String, isFolder: Bool, isDuplicate: Bool = false) {
        self.name = name
        self.isFolder = isFolder
        self.isDuplicate = isDuplicate
    }

    func folder(named name: String) -> StyleNode {
        if let existing = foldersByName[name] { return existing }
        let folder = StyleNode(name: name, isFolder: true)
        foldersByName[name] = folder
        add(folder)
        return folder
    }

    func add(_ child: StyleNode) {
        child.parent = self
        children.append(child)
    }

    /// Styles that can be exported: everything under a folder, or the style itself.
    public var exportableStyles: [StyleNode] {
        isFolder ? children.flatMap(\.exportableStyles) : (isDuplicate ? [] : [self])
    }

    public var isExportable: Bool { !exportableStyles.isEmpty }

    public var checkState: CheckState {
        if !isFolder { return checked ? .on : .off }
        let styles = exportableStyles
        let selected = styles.filter(\.checked).count
        if selected == 0 { return .off }
        return selected == styles.count ? .on : .mixed
    }

    /// Selects or deselects a style; on a folder, selects everything inside unless it's all selected already.
    public func toggle() {
        let newValue = checkState != .on
        for style in exportableStyles { style.checked = newValue }
    }

    /// Selected style names in tree order, each name once.
    public var checkedStyleNames: [String] {
        var seen: Set<String> = []
        return exportableStyles.filter(\.checked).map(\.name).filter { seen.insert($0).inserted }
    }

    /// Selects the styles with these names.
    public func check(names: Set<String>) {
        for style in exportableStyles where names.contains(style.name) { style.checked = true }
    }
}

/// Capture One's styles arranged in their folders, as its Styles menu shows them.
///
/// Capture One's scripting interface only reports plain style names, in menu order. The folders
/// come from the style files on disk: built-in styles inside the app, user styles in
/// `~/Library/Application Support/Capture One/Styles`. Names Capture One reports that aren't
/// style files (tool presets) are left out.
public struct StyleTree {
    /// One line of a text listing of the tree.
    public struct Row: Equatable {
        /// Indented text. Unique within the tree.
        public var display: String
        /// The styles this row stands for: one for a style, everything inside for a folder.
        /// Empty for a duplicate.
        public var styleNames: [String]
        public var isFolder: Bool
    }

    public struct Root {
        public var label: String
        public var directory: URL

        public init(label: String, directory: URL) {
            self.label = label
            self.directory = directory
        }
    }

    public static func standardRoots(app: URL) -> [Root] {
        [
            Root(label: "Built-in Styles", directory: app.appendingPathComponent("Contents/Resources/Styles")),
            Root(label: "User Styles", directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Capture One/Styles")),
        ]
    }

    static let folderMark = "📁 "
    static let indent = "\u{2003}\u{2003}"
    public static let duplicateNote = " (same name as an earlier style, can’t be exported)"

    /// The invisible top of the tree; its children are the roots' labels.
    public let root: StyleNode

    /// - Parameters:
    ///   - available: Capture One's `available styles`, in its order.
    ///   - roots: where style files live, each shown as a top-level folder.
    public init(available: [String], roots: [Root]) {
        // Folder paths of every style file, by style name.
        var locations: [String: [[String]]] = [:]
        for root in roots {
            let base = root.directory.resolvingSymlinksInPath()
            let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
            var found: [(name: String, folders: [String])] = []
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "costyle" else { continue }
                let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
                let relative = Array(parent.dropFirst(base.pathComponents.count))
                found.append((url.deletingPathExtension().lastPathComponent, [root.label] + relative))
            }
            found.sort { $0.folders.joined(separator: "/").localizedStandardCompare($1.folders.joined(separator: "/")) == .orderedAscending }
            for style in found {
                locations[style.name, default: []].append(style.folders)
            }
        }

        // Place the styles in Capture One's order; folders appear where their first style does.
        let top = StyleNode(name: "", isFolder: true)
        var seen: Set<String> = []
        for name in available {
            guard var paths = locations[name], !paths.isEmpty else { continue }
            let folders = paths.removeFirst()
            locations[name] = paths
            var folder = top
            for component in folders { folder = folder.folder(named: component) }
            folder.add(StyleNode(name: name, isFolder: false, isDuplicate: seen.contains(name)))
            seen.insert(name)
        }
        root = top
    }

    /// The tree as indented text, one row per folder and style.
    public var rows: [Row] {
        var rows: [Row] = []
        var used: Set<String> = []
        func walk(_ node: StyleNode, depth: Int) {
            for child in node.children {
                var display = String(repeating: Self.indent, count: depth)
                    + (child.isFolder ? Self.folderMark : "") + child.name
                    + (child.isDuplicate ? Self.duplicateNote : "")
                while used.contains(display) { display += "\u{2060}" }  // invisible, keeps rows distinct
                used.insert(display)
                rows.append(Row(display: display, styleNames: child.exportableStyles.map(\.name),
                                isFolder: child.isFolder))
                if child.isFolder { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return rows
    }
}
