import AppKit
import C1LUTCore

/// The window for choosing what to export: a LUT target and Capture One's styles as a tree
/// with disclosure triangles and checkboxes. A folder's checkbox selects everything inside it.
final class StylePicker: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
    struct Choice {
        var target: Target
        var styles: [String]
    }

    private let root: StyleNode
    private let targets: [Target]
    private let window: NSWindow
    private let outline = PickerOutlineView()
    private let targetMenu = NSPopUpButton()
    private let targetSummary = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private var choice: Choice?

    init(tree: StyleTree, targets: [Target], initialTarget: Target) {
        root = tree.root
        self.targets = targets
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()

        window.title = "Export Styles as LUTs"
        window.minSize = NSSize(width: 420, height: 360)
        window.level = .floating  // stay above Capture One, which started us
        window.delegate = self
        window.isReleasedWhenClosed = false

        for target in targets {
            targetMenu.addItem(withTitle: target.title)
        }
        targetMenu.selectItem(at: targets.firstIndex { $0.id == initialTarget.id } ?? 0)
        targetMenu.target = self
        targetMenu.action = #selector(targetChanged)
        targetSummary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        targetSummary.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("style"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = true
        outline.usesAutomaticRowHeights = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.onSpace = { [weak self] in self?.toggleSelectedRows() }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        exportButton.keyEquivalent = "\r"

        let hint = NSTextField(labelWithString: "Select styles, or a folder to export everything in it.")
        hint.textColor = .secondaryLabelColor
        countLabel.textColor = .secondaryLabelColor

        let targetRow = NSStackView(views: [NSTextField(labelWithString: "LUTs for:"), targetMenu])
        targetRow.spacing = 8
        let buttons = NSStackView(views: [countLabel, NSView(), cancelButton, exportButton])
        buttons.spacing = 8
        let content = NSStackView(views: [targetRow, targetSummary, hint, scroll, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(16, after: targetSummary)
        content.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        window.contentView = container
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40),
            targetSummary.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        exportButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        outline.reloadData()
        // Like Capture One: the top groups open, their folders closed.
        for group in root.children { outline.expandItem(group) }
        targetChanged()
        refresh()
    }

    // MARK: Running

    /// Shows the window until Export or Cancel. Returns nil when cancelled.
    func run() -> Choice? {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(ignoringOtherApps: true)
        }
        app.runModal(for: window)
        window.orderOut(nil)
        return choice
    }

    /// Draws the window into a PNG without showing it, after selecting the named styles or
    /// folders and opening their folders. For checking the layout.
    func snapshot(to url: URL, toggling names: [String]) throws {
        // Offscreen drawing mixes light controls with dark text; one fixed appearance avoids that.
        window.appearance = NSAppearance(named: .aqua)
        for name in names {
            guard let node = find(name, in: root) else { continue }
            node.toggle()
            var ancestor = node.parent
            var chain: [StyleNode] = []
            while let a = ancestor, a !== root { chain.insert(a, at: 0); ancestor = a.parent }
            chain.forEach { outline.expandItem($0) }
            if node.isFolder { outline.expandItem(node) }
        }
        refresh()
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func find(_ name: String, in node: StyleNode) -> StyleNode? {
        for child in node.children {
            if child.name == name { return child }
            if let found = find(name, in: child) { return found }
        }
        return nil
    }

    // MARK: Actions

    @objc private func targetChanged() {
        targetSummary.stringValue = targets[max(targetMenu.indexOfSelectedItem, 0)].summary
    }

    @objc private func exportClicked() {
        choice = Choice(target: targets[max(targetMenu.indexOfSelectedItem, 0)], styles: root.checkedStyleNames)
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        choice = nil
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }

    @objc fileprivate func checkboxClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let node = outline.item(atRow: row) as? StyleNode else { return }
        node.toggle()
        refresh()
    }

    @objc private func rowDoubleClicked() {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? StyleNode else { return }
        if node.isFolder {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            node.toggle()
            refresh()
        }
    }

    private func toggleSelectedRows() {
        for row in outline.selectedRowIndexes {
            (outline.item(atRow: row) as? StyleNode)?.toggle()
        }
        refresh()
    }

    /// Updates every visible checkbox and the count after a change.
    private func refresh() {
        for row in 0..<outline.numberOfRows {
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? StyleCell,
               let node = outline.item(atRow: row) as? StyleNode {
                cell.update(from: node)
            }
        }
        let count = root.checkedStyleNames.count
        countLabel.stringValue = count == 0 ? "No styles selected" : count == 1 ? "1 style selected" : "\(count) styles selected"
        exportButton.isEnabled = count > 0
    }

    // MARK: Outline data

    private func node(_ item: Any?) -> StyleNode {
        (item as? StyleNode) ?? root
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        node(item).isFolder
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = (outlineView.makeView(withIdentifier: StyleCell.identifier, owner: self) as? StyleCell) ?? StyleCell()
        cell.checkbox.target = self
        cell.checkbox.action = #selector(checkboxClicked(_:))
        cell.update(from: node(item))
        return cell
    }
}

/// Space selects or deselects the highlighted rows.
private final class PickerOutlineView: NSOutlineView {
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onSpace?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A row: checkbox, an outlined folder icon for folders, name.
private final class StyleCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("StyleCell")
    // Outlined and single-colour, in the spirit of Capture One's Styles tool.
    static let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))

    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var labelAfterIcon: NSLayoutConstraint!
    private var labelAfterCheckbox: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingTail
        imageView = icon
        textField = label
        for view in [checkbox, icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Folders show their icon between checkbox and name; styles have none.
        labelAfterIcon = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        labelAfterCheckbox = label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(from node: StyleNode) {
        label.stringValue = node.name
        icon.image = node.isFolder ? Self.folderIcon : nil
        icon.isHidden = !node.isFolder
        labelAfterCheckbox.isActive = !node.isFolder
        labelAfterIcon.isActive = node.isFolder
        checkbox.allowsMixedState = node.isFolder
        switch node.checkState {
        case .on: checkbox.state = .on
        case .off: checkbox.state = .off
        case .mixed: checkbox.state = .mixed
        }
        checkbox.isEnabled = node.isExportable
        label.textColor = node.isExportable ? .labelColor : .tertiaryLabelColor
        toolTip = node.isDuplicate
            ? "Capture One can only use the first style named “\(node.name)”. Rename this one in Capture One to export it."
            : nil
    }
}
