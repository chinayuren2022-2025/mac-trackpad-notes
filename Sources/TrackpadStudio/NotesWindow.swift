import AppKit

/// The main window: notes list on the left, the writing board on the right.
/// Owns the library and autosaves the open note.
final class NotesWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let board = BoardTabView()
    let library: NoteLibrary
    private let sidebar = NotesSidebar()
    private let sidebarWidth: CGFloat = 232
    private(set) var currentID: String?

    /// Debounced save: after the pen rests, and at least every few seconds
    /// during long writing so a crash never loses more than that.
    private var dirtySince: Date?
    private var saveWork: DispatchWorkItem?
    private var isLoading = false

    var isSidebarVisible: Bool {
        get { !sidebar.isHidden }
        set {
            sidebar.isHidden = !newValue
            UserDefaults.standard.set(!newValue, forKey: "sidebarHidden")
            layoutViews()
        }
    }

    init(library: NoteLibrary) {
        self.library = library
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "手写笔记"
        window.isReleasedWhenClosed = false   // closing only hides: the hot key keeps working
        window.delegate = self
        window.minSize = NSSize(width: 960, height: 640)
        // The page is white paper; a light frame around it reads as one surface.
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameAutosaveName("NotesWindow")
        if window.frame.origin == .zero { window.center() }

        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.postsFrameChangedNotifications = true
        container.addSubview(sidebar)
        container.addSubview(board)
        window.contentView = container
        NotificationCenter.default.addObserver(
            self, selector: #selector(containerResized), name: NSView.frameDidChangeNotification, object: container
        )
        sidebar.isHidden = UserDefaults.standard.bool(forKey: "sidebarHidden")
        layoutViews()

        board.onContentChange = { [weak self] in self?.noteChanged() }
        board.onModeChange = { [weak self] writing in self?.sidebar.isInteractive = !writing }
        sidebar.isInteractive = !board.isWriting
        sidebar.onSelect = { [weak self] id in self?.open(id) }
        sidebar.onNew = { [weak self] in self?.newNote() }
        sidebar.onRename = { [weak self] id in self?.rename(id) }
        sidebar.onDuplicate = { [weak self] id in self?.duplicate(id) }
        sidebar.onDelete = { [weak self] id in self?.trash(id) }
        sidebar.thumbnailProvider = { [weak library] id in library?.thumbnail(id) }

        let last = UserDefaults.standard.string(forKey: "lastNoteID")
        if let id = last, library.info(id) != nil {
            open(id)
        } else if let first = library.notes.first {
            open(first.id)
        } else {
            newNote()
        }
    }

    @objc private func containerResized() { layoutViews() }

    private func layoutViews() {
        guard let bounds = window.contentView?.bounds else { return }
        let width = sidebar.isHidden ? 0 : sidebarWidth
        sidebar.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        board.frame = CGRect(x: width, y: 0, width: bounds.width - width, height: bounds.height)
    }

    private func reloadSidebar() {
        sidebar.reload(notes: library.notes, selected: currentID)
    }

    // MARK: Notes

    func open(_ id: String) {
        guard id != currentID else { return }
        saveNow()
        board.commitPendingEdits()
        saveNow()
        isLoading = true
        defer { isLoading = false }
        do {
            try board.loadNote(library.data(for: id), paper: defaultPaper)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法打开这条笔记"
            alert.runModal()
            return
        }
        currentID = id
        dirtySince = nil
        UserDefaults.standard.set(id, forKey: "lastNoteID")
        updateTitles()
        reloadSidebar()
    }

    func newNote() {
        saveNow()
        board.commitPendingEdits()
        saveNow()
        let note = library.create()
        currentID = nil
        open(note.id)
        board.enterWritingMode()
    }

    var defaultPaper: PaperStyle {
        PaperStyle(rawValue: UserDefaults.standard.string(forKey: "defaultPaper") ?? "") ?? .grid
    }

    func setPaper(_ paper: PaperStyle) {
        board.paper = paper
        UserDefaults.standard.set(paper.rawValue, forKey: "defaultPaper")
    }

    func rename(_ id: String? = nil) {
        guard let id = id ?? currentID, let info = library.info(id) else { return }
        let alert = NSAlert()
        alert.messageText = "重命名笔记"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = info.title
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.rename(id, to: field.stringValue)
        if id == currentID { updateTitles() }
        reloadSidebar()
    }

    func duplicate(_ id: String? = nil) {
        guard let id = id ?? currentID else { return }
        saveNow()
        if let copy = library.duplicate(id) { open(copy.id) }
    }

    func trash(_ id: String? = nil) {
        guard let id = id ?? currentID, let info = library.info(id) else { return }
        let alert = NSAlert()
        alert.messageText = "把“\(info.title)”移到废纸篓？"
        alert.informativeText = "之后可以在访达的废纸篓里找回。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if id == currentID {
            board.commitPendingEdits()
            saveWork?.cancel()
            dirtySince = nil
            currentID = nil
        }
        library.trash(id)
        if currentID == nil {
            if let next = library.notes.first { open(next.id) } else { newNote() }
        }
        reloadSidebar()
    }

    /// Imports a `.trackpad.json` file as a new note.
    func importFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            try BoardModel().loadDocument(data)   // validate before adding
            let title = url.lastPathComponent
                .replacingOccurrences(of: ".trackpad.json", with: "")
                .replacingOccurrences(of: ".json", with: "")
            let note = library.create(title: title, data: data)
            open(note.id)
            saveNow(force: true)   // thumbnail
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法导入“\(url.lastPathComponent)”"
            alert.informativeText = "这不是本应用保存的笔迹文件，或文件已损坏。"
            alert.runModal()
        }
    }

    // MARK: Autosave

    private func noteChanged() {
        guard !isLoading else { return }
        if dirtySince == nil { dirtySince = Date() }
        saveWork?.cancel()
        let elapsed = Date().timeIntervalSince(dirtySince ?? Date())
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (elapsed > 8 ? 0 : 1.2), execute: work)
    }

    /// Writes the open note if it changed. `sync` waits for the disk (quit).
    func saveNow(sync: Bool = false, force: Bool = false) {
        saveWork?.cancel()
        saveWork = nil
        guard let id = currentID, dirtySince != nil || force,
              let data = try? board.noteData() else { return }
        dirtySince = nil
        library.save(id, data: data, thumbnail: board.thumbnailPNG(maxSize: NotesSidebar.thumbnailSize), sync: sync)
        reloadSidebar()
    }

    func prepareToQuit() {
        board.commitPendingEdits()
        saveNow(sync: true)
        library.flush()
    }

    func windowWillClose(_ notification: Notification) {
        prepareToQuit()
    }

    // MARK: Floating mini window

    /// The window currently holding the board (for sheets and dialogs).
    var activeWindow: NSWindow { board.window ?? window }

    private lazy var floatingPanel: FloatingNotePanel = {
        let panel = FloatingNotePanel()
        panel.delegate = self
        return panel
    }()

    var isFloatingVisible: Bool { floatingPanel.isVisible }

    private func updateTitles() {
        let title = currentID.flatMap { library.info($0)?.title } ?? "手写笔记"
        window.title = title
        floatingPanel.title = title
    }

    /// The global shortcut: show the mini window over whatever is in front
    /// (full-screen apps included); if it is already in use, hide it.
    func toggleFloating() {
        if floatingPanel.isVisible, floatingPanel.isKeyWindow {
            hideFloating()
        } else {
            showFloating()
        }
    }

    func showFloating(movePointer: Bool = true) {
        if board.window !== floatingPanel {
            window.orderOut(nil)
            board.removeFromSuperview()
            board.frame = floatingPanel.contentView?.bounds ?? .zero
            board.autoresizingMask = [.width, .height]
            floatingPanel.contentView?.addSubview(board)
        }
        updateTitles()
        // Non-activating: activating this app would leave another app's
        // full-screen space (tested). The pointer is handled by
        // `BackgroundCursor` instead.
        floatingPanel.orderFrontRegardless()
        floatingPanel.makeKey()
        // The writing mode freezes the pointer where it is; it must sit over
        // the panel, or a press would land in the app behind.
        // (Quartz display space: y down from the top of the primary screen.)
        let frame = floatingPanel.frame
        if movePointer, let primary = NSScreen.screens.first {
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: primary.frame.maxY - frame.midY))
        }
        board.enterWritingMode()
        // Diagnostics for the over-full-screen case, which only the user's
        // machine can reproduce: …/TrackpadStudio-Handwriting/floating.log
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.logFloatingState()
        }
    }

    private func logFloatingState() {
        let panel = floatingPanel
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let line = "\(Date()) front=\(front) visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) "
            + "key=\(panel.isKeyWindow) appActive=\(NSApp.isActive) "
            + "occluded=\(!panel.occlusionState.contains(.visible)) frame=\(panel.frame) "
            + "pointerHidden=\(BackgroundCursor.isHidden) rawFrames=\(MultitouchReader.shared.hasDeliveredFrames)\n"
        let url = library.folder.deletingLastPathComponent().appendingPathComponent("floating.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    func hideFloating() {
        board.commitPendingEdits()
        saveNow()
        floatingPanel.orderOut(nil)
    }

    /// Back to the full window (Dock icon, menu bar item, or panel button).
    func showMainWindow() {
        if floatingPanel.isVisible { floatingPanel.orderOut(nil) }
        if board.superview !== window.contentView {
            board.removeFromSuperview()
            board.autoresizingMask = []
            window.contentView?.addSubview(board)
            layoutViews()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === floatingPanel else { return true }
        hideFloating()
        return false
    }

    // MARK: Export

    func export(kind: ExportKind) {
        board.commitPendingEdits()
        guard !board.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "这条笔记还是空的"
            alert.runModal()
            return
        }
        board.enterPointerModeForDialog()
        let title = library.info(currentID ?? "")?.title ?? "笔记"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title + "." + kind.fileExtension
        panel.title = kind.panelTitle
        panel.beginSheetModal(for: activeWindow) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let data: Data?
            switch kind {
            case .pdf: data = self.board.pdfData()
            case .png: data = self.board.pngData()
            case .archive: data = try? self.board.noteData()
            }
            do {
                guard let data else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    enum ExportKind {
        case pdf, png, archive

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .png: return "png"
            case .archive: return "trackpad.json"
            }
        }

        var panelTitle: String {
            switch self {
            case .pdf: return "导出 PDF（整条笔记）"
            case .png: return "导出 PNG 图片（整条笔记）"
            case .archive: return "导出可编辑笔迹文件"
            }
        }
    }
}

// MARK: - Sidebar

/// Notes list: search, new-note button, rows with thumbnail, title and date.
/// Takes no clicks while the board is in writing mode, so a hard press on
/// the trackpad can never switch notes mid-sentence.
final class NotesSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    static let thumbnailSize = CGSize(width: 64, height: 44)

    var onSelect: ((String) -> Void)?
    var onNew: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onDuplicate: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var thumbnailProvider: ((String) -> NSImage?)?
    var isInteractive = true {
        didSet {
            scroll.alphaValue = isInteractive ? 1 : 0.55
            hint.isHidden = isInteractive
        }
    }

    private var all: [NoteInfo] = []
    private var shown: [NoteInfo] = []
    private var selectedID: String?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let search = NSSearchField()
    private let newButton = NSButton()
    private let hint = NSTextField(labelWithString: "书写中 · 按 Esc 后可选择笔记")
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.955, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "笔记")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = CGRect(x: 14, y: 0, width: 120, height: 22)
        title.autoresizingMask = [.minYMargin]
        title.tag = 1
        addSubview(title)

        newButton.bezelStyle = .texturedRounded
        newButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "新建笔记")
        newButton.toolTip = "新建笔记（⌘N）"
        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(newButton)

        search.placeholderString = "搜索笔记标题"
        search.delegate = self
        search.autoresizingMask = [.width, .minYMargin]
        addSubview(search)

        let column = NSTableColumn(identifier: .init("note"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        // Keeps keyboard focus (⌘Z, keys) on the board.
        table.refusesFirstResponder = true
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.autoresizingMask = [.width, .maxYMargin]
        hint.isHidden = true
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    override var frame: NSRect {
        didSet { layoutContent() }
    }

    private func layoutContent() {
        let b = bounds
        viewWithTag(1)?.frame = CGRect(x: 14, y: b.maxY - 40, width: 120, height: 22)
        newButton.frame = CGRect(x: b.maxX - 44, y: b.maxY - 42, width: 32, height: 26)
        search.frame = CGRect(x: 10, y: b.maxY - 76, width: b.width - 20, height: 26)
        hint.frame = CGRect(x: 8, y: 10, width: b.width - 16, height: 16)
        scroll.frame = CGRect(x: 0, y: 34, width: b.width, height: max(0, b.maxY - 86 - 34))
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0, alpha: 0.1).setFill()
        NSBezierPath(rect: CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height)).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    func reload(notes: [NoteInfo], selected: String?) {
        all = notes
        selectedID = selected
        applyFilter()
    }

    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let id = selectedID, let row = shown.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    @objc private func newClicked() { onNew?() }

    @objc private func doubleClicked() {
        guard shown.indices.contains(table.clickedRow) else { return }
        onRename?(shown[table.clickedRow].id)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = shown[row]
        let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? NoteCell) ?? NoteCell()
        cell.identifier = .init("cell")
        cell.titleLabel.stringValue = note.title
        cell.dateLabel.stringValue = dateFormatter.string(from: note.modified)
        cell.thumb.image = thumbnailProvider?(note.id)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard shown.indices.contains(table.selectedRow) else { return }
        let id = shown[table.selectedRow].id
        guard id != selectedID else { return }
        selectedID = id
        onSelect?(id)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard shown.indices.contains(table.clickedRow) else { return }
        let id = shown[table.clickedRow].id
        for (title, action) in [("重命名…", #selector(menuRename(_:))),
                                ("复制笔记", #selector(menuDuplicate(_:))),
                                ("移到废纸篓…", #selector(menuDelete(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
    }

    @objc private func menuRename(_ sender: NSMenuItem) { (sender.representedObject as? String).map { onRename?($0) } }
    @objc private func menuDuplicate(_ sender: NSMenuItem) { (sender.representedObject as? String).map { onDuplicate?($0) } }
    @objc private func menuDelete(_ sender: NSMenuItem) { (sender.representedObject as? String).map { onDelete?($0) } }
}

private final class NoteCell: NSTableCellView {
    let thumb = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let dateLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = NSColor.white.cgColor
        thumb.layer?.cornerRadius = 4
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor(calibratedWhite: 0, alpha: 0.1).cgColor
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor
        [thumb, titleLabel, dateLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let s = NotesSidebar.thumbnailSize
        thumb.frame = CGRect(x: 10, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        let x = thumb.frame.maxX + 10
        titleLabel.frame = CGRect(x: x, y: bounds.midY + 1, width: bounds.width - x - 8, height: 18)
        dateLabel.frame = CGRect(x: x, y: bounds.midY - 17, width: bounds.width - x - 8, height: 15)
    }
}

/// The mini window: floats above every app and every Space, full-screen
/// apps included, without taking focus from them (non-activating). Dragged
/// by its title bar; position and size are remembered.
final class FloatingNotePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "手写笔记"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        appearance = NSAppearance(named: .aqua)
        // The toolbar needs about this much height to stay usable.
        minSize = NSSize(width: 460, height: 470)
        if !setFrameUsingName("FloatingNotePanel"), let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.minY + 24))
        }
        setFrameAutosaveName("FloatingNotePanel")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
