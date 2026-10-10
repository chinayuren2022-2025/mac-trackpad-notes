import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var notes: NotesWindowController?
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var boardView: BoardTabView? { notes?.board }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        // The private reader (contact shape, needs Input Monitoring) only runs
        // when shape-based pen detection is on.
        if UserDefaults.standard.object(forKey: "palmUseContactSize") as? Bool ?? true {
            MultitouchReader.shared.start()
        }

        // Test modes must never touch the real notes.
        let args = CommandLine.arguments
        let isTestRun = args.contains("--snapshot") || args.contains("--bench")
        let folder = isTestRun
            ? FileManager.default.temporaryDirectory.appendingPathComponent("notes-test-\(UUID().uuidString)")
            : NoteLibrary.defaultFolder
        let notes = NotesWindowController(library: NoteLibrary(folder: folder))
        self.notes = notes
        notes.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !isTestRun { installQuickAccess() }
        BackgroundCursor.isEnabled = !isTestRun

        if let idx = args.firstIndex(of: "--snapshot"), args.count > idx + 1 {
            runSnapshotMode(directory: args[idx + 1])
        }

        // Render benchmark: --bench recording.jsonl copies
        if let idx = args.firstIndex(of: "--bench"), args.count > idx + 2 {
            DispatchQueue.main.async {
                notes.board.runRenderBenchmark(
                    recording: URL(fileURLWithPath: args[idx + 1]),
                    copies: Int(args[idx + 2]) ?? 10
                )
                NSApp.terminate(nil)
            }
        }
    }

    /// Self-screenshot mode: a few demo notes in a throwaway library, the
    /// window rendered to PNGs, then quit. Needs no screen-recording
    /// permission because an app may always rasterize its own views.
    private func runSnapshotMode(directory: String) {
        guard let notes else { return }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (title, paper) in [("线性代数 第三讲", PaperStyle.lined), ("草稿", .dots)] {
            notes.newNote()
            notes.library.rename(notes.currentID ?? "", to: title)
            notes.setPaper(paper)
            notes.board.seedDemoContent()
            notes.saveNow(force: true)
        }
        notes.newNote()
        notes.board.seedDemoContent()
        notes.saveNow(force: true)
        notes.board.enterPointerModeForDialog()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            if let content = notes.window.contentView {
                writePNG(of: content, to: dir.appendingPathComponent("window.png"))
                notes.board.enterWritingMode()
                content.layoutSubtreeIfNeeded()
                writePNG(of: content, to: dir.appendingPathComponent("window-writing.png"))
            }
            // The mini window at its minimum size: the toolbar must still fit.
            notes.showFloating(movePointer: false)
            notes.activeWindow.setContentSize(notes.activeWindow.minSize)
            if let panel = notes.activeWindow.contentView {
                panel.layoutSubtreeIfNeeded()
                writePNG(of: panel, to: dir.appendingPathComponent("floating-min.png"))
            }
            notes.showMainWindow()
            if let pdf = notes.board.pdfData() {
                try? pdf.write(to: dir.appendingPathComponent("note.pdf"))
            }
            if let png = notes.board.pngData() {
                try? png.write(to: dir.appendingPathComponent("note.png"))
            }
            NSApp.terminate(nil)
        }
    }

    private func writePNG(of view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        notes?.prepareToQuit()
        // Compressed at the next launch if gzip does not get to run now.
        TouchRecorder.shared.closeSession()
        FreeformConnector.shared.disarm()
        MultitouchReader.shared.stop()
    }

    /// Stay running with every window closed: the shortcut and the menu bar
    /// icon must still bring the notes up.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notes?.showMainWindow()
        return false
    }

    // MARK: Quick access (⌃⌥N and the menu bar icon)

    private func installQuickAccess() {
        hotKey = GlobalHotKey(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey) { [weak self] in
            self?.notes?.toggleFloating()
        }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: "手写笔记")
            ?? NSImage(systemSymbolName: "pencil", accessibilityDescription: "手写笔记")
        let menu = NSMenu()
        menu.addItem(item("打开 / 隐藏小窗（⌃⌥N）", #selector(toggleFloating(_:)), target: self))
        menu.addItem(item("新建笔记并打开小窗", #selector(newFloatingNote(_:)), target: self))
        menu.addItem(item("打开主窗口", #selector(showMainWindow(_:)), target: self))
        menu.addItem(.separator())
        menu.addItem(item("退出手写笔记", #selector(NSApplication.terminate(_:)), target: NSApp))
        status.menu = menu
        statusItem = status
        if hotKey == nil {
            let alert = NSAlert()
            alert.messageText = "快捷键 ⌃⌥N 被其他应用占用"
            alert.informativeText = "仍可以点菜单栏右上角的笔形图标打开小窗。"
            alert.runModal()
        }
    }

    @objc private func toggleFloating(_ sender: Any?) { notes?.toggleFloating() }
    @objc private func showMainWindow(_ sender: Any?) { notes?.showMainWindow() }
    @objc private func newFloatingNote(_ sender: Any?) {
        notes?.newNote()
        notes?.showFloating()
    }

    // MARK: File

    @objc private func newNote(_ sender: Any?) { notes?.newNote() }
    @objc private func renameNote(_ sender: Any?) { notes?.rename() }
    @objc private func duplicateNote(_ sender: Any?) { notes?.duplicate() }
    @objc private func trashNote(_ sender: Any?) { notes?.trash() }
    @objc private func exportPDF(_ sender: Any?) { notes?.export(kind: .pdf) }
    @objc private func exportPNG(_ sender: Any?) { notes?.export(kind: .png) }
    @objc private func exportArchive(_ sender: Any?) { notes?.export(kind: .archive) }

    @objc private func importNote(_ sender: Any?) {
        guard let notes else { return }
        notes.board.enterPointerModeForDialog()
        let panel = NSOpenPanel()
        panel.title = "导入笔迹文件（.trackpad.json）"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: notes.activeWindow) { response in
            guard response == .OK else { return }
            panel.urls.forEach(notes.importFile)
        }
    }

    @objc private func revealNotesFolder(_ sender: Any?) {
        guard let notes else { return }
        NSWorkspace.shared.activateFileViewerSelecting([notes.library.folder])
    }

    // MARK: Edit / tools / view

    @objc private func clearNote(_ sender: Any?) {
        guard let boardView, !boardView.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清空这条笔记的全部内容？"
        alert.informativeText = "可以用 ⌘Z 撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        boardView.clearBoard()
    }

    @objc private func selectTool(_ sender: NSMenuItem) {
        guard let tool = BoardTool(rawValue: sender.tag) else { return }
        boardView?.selectToolFromMenu(tool)
    }

    @objc private func toggleSmoothStrokes(_ sender: NSMenuItem) {
        guard let boardView else { return }
        boardView.smoothStrokes.toggle()
        sender.state = boardView.smoothStrokes ? .on : .off
    }

    @objc private func toggleWholeStrokeEraser(_ sender: NSMenuItem) {
        guard let boardView else { return }
        boardView.eraseWholeStrokes.toggle()
        sender.state = boardView.eraseWholeStrokes ? .on : .off
    }

    @objc private func selectPaper(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let paper = PaperStyle(rawValue: raw) else { return }
        notes?.setPaper(paper)
    }

    @objc private func actualSize(_ sender: Any?) { boardView?.resetView() }
    @objc private func zoomIn(_ sender: Any?) { boardView?.zoom(by: 1.25) }
    @objc private func zoomOut(_ sender: Any?) { boardView?.zoom(by: 0.8) }
    @objc private func toggleSidebar(_ sender: Any?) {
        guard let notes else { return }
        notes.isSidebarVisible.toggle()
    }
    @objc private func toggleWriting(_ sender: Any?) { boardView?.toggleWritingMode() }
    @objc private func toggleDebugInfo(_ sender: NSMenuItem) {
        guard let boardView else { return }
        boardView.showDebugInfo.toggle()
        sender.state = boardView.showDebugInfo ? .on : .off
    }

    // MARK: Palm rejection

    @objc private func selectWritingTrigger(_ sender: NSMenuItem) {
        boardView?.drawOnContact = sender.tag == 1
    }

    @objc private func calibratePressure(_ sender: Any?) {
        boardView?.startPressureCalibration()
    }

    /// The writing-trigger radio follows the board (calibration switches it).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectWritingTrigger(_:)), let boardView {
            menuItem.state = (menuItem.tag == 1) == boardView.drawOnContact ? .on : .off
        }
        return true
    }

    @objc private func togglePalmRejection(_ sender: NSMenuItem) {
        guard let boardView else { return }
        boardView.palmRejectionEnabled.toggle()
        sender.state = boardView.palmRejectionEnabled ? .on : .off
    }

    @objc private func selectHand(_ sender: NSMenuItem) {
        guard let boardView, let hand = sender.representedObject as? String,
              let value = PalmRejector.Hand(rawValue: hand) else { return }
        boardView.palmHand = value
        sender.menu?.items.filter { $0.action == #selector(selectHand(_:)) }
            .forEach { $0.state = ($0.representedObject as? String) == hand ? .on : .off }
    }

    @objc private func recordTouches(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        MultitouchReader.shared.start()
        let recorder = TouchRecorder.shared
        recorder.onFinish = { [weak self] url, mtFrames, nsFrames in
            if !(UserDefaults.standard.object(forKey: "palmUseContactSize") as? Bool ?? true),
               !FreeformConnector.shared.isArmed {
                MultitouchReader.shared.stop()
            }
            self?.reportRecording(url: url, mtFrames: mtFrames, nsFrames: nsFrames)
        }
        recorder.start(label: label, seconds: 20)
    }

    @objc private func toggleContinuousLog(_ sender: NSMenuItem) {
        let recorder = TouchRecorder.shared
        recorder.isContinuous.toggle()
        if recorder.isContinuous { MultitouchReader.shared.start() }
        sender.state = recorder.isContinuous ? .on : .off
    }

    @objc private func revealTouchLog(_ sender: Any?) {
        let dir = TouchRecorder.continuousDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func reportRecording(url: URL, mtFrames: Int, nsFrames: Int) {
        let alert = NSAlert()
        alert.messageText = "录制完成：\(url.lastPathComponent)"
        if nsFrames > 0 && mtFrames == 0 {
            alert.informativeText = "记录到 \(nsFrames) 帧触点，但没有面积数据。请在“系统设置 → 隐私与安全性 → 输入监控”中允许“Trackpad Studio 手写”，然后退出并重新打开本应用，再录一次。"
            alert.addButton(withTitle: "打开输入监控设置")
            alert.addButton(withTitle: "好")
            if alert.runModal() == .alertFirstButtonReturn,
               let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(settings)
            }
            return
        }
        alert.informativeText = "系统触点 \(nsFrames) 帧，面积数据 \(mtFrames) 帧。可以继续录下一项。"
        alert.runModal()
    }

    @objc private func toggleFreeformConnector(_ sender: NSMenuItem) {
        let connector = FreeformConnector.shared
        connector.onStateChange = { [weak sender] in
            sender?.state = connector.isArmed ? .on : .off
        }
        if connector.isArmed {
            connector.disarm()
            return
        }
        switch connector.arm() {
        case .success:
            let alert = NSAlert()
            alert.messageText = "无边记连接器已开启"
            alert.informativeText = "切换到无边记，选中画笔工具，就可以在触控板上用笔书写。蓝色虚线框是书写区域，对应整个触控板。\n\n书写模式下触控板不再移动指针；需要点工具栏时，按 ⌃⌥⌘F 切到鼠标模式，再按一次切回书写。双指仍可拖动和缩放画布。菜单栏的“✎”显示当前状态。"
            alert.runModal()
        case .failure(.accessibility):
            let alert = NSAlert()
            alert.messageText = "需要“辅助功能”权限"
            alert.informativeText = "连接器需要模拟鼠标书写，并屏蔽触控板原有的指针操作。请在“系统设置 → 隐私与安全性 → 辅助功能”里打开“Trackpad Studio 手写”，然后再开启连接器。"
            alert.addButton(withTitle: "打开辅助功能设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .failure(.eventTap):
            let alert = NSAlert()
            alert.messageText = "无法开启连接器"
            alert.informativeText = "系统拒绝创建事件监听。请确认已在“辅助功能”和“输入监控”中授权本应用，然后完全退出（⌘Q）并重新打开。"
            alert.runModal()
        }
    }

    @objc private func togglePenAim(_ sender: NSMenuItem) {
        guard let boardView else { return }
        boardView.showPenAim.toggle()
        sender.state = boardView.showPenAim ? .on : .off
    }

    @objc private func toggleCameraPen(_ sender: NSMenuItem) {
        guard let boardView else { return }
        boardView.showCameraPen.toggle()
        sender.state = boardView.showCameraPen ? .on : .off
        if boardView.showCameraPen, CameraPen.shared.calibration == nil {
            CameraAlignWindowController.shared.present()
        }
    }

    @objc private func alignCamera(_ sender: Any?) { CameraAlignWindowController.shared.present() }

    @objc private func toggleAllowFinger(_ sender: NSMenuItem) {
        guard let boardView else { return }
        boardView.allowFinger.toggle()
        sender.state = boardView.allowFinger ? .on : .off
    }

    @objc private func toggleContactSize(_ sender: NSMenuItem) {
        guard let boardView else { return }
        boardView.useContactSize.toggle()
        sender.state = boardView.useContactSize ? .on : .off
    }

    // MARK: Menus

    private func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func submenu(_ title: String, in main: NSMenu, _ items: [NSMenuItem]) -> NSMenu {
        let holder = NSMenuItem()
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private func installMainMenu() {
        let main = NSMenu()
        let defaults = UserDefaults.standard

        _ = submenu("手写笔记", in: main, [
            item("关于手写笔记", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
            .separator(),
            item("隐藏手写笔记", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("退出手写笔记", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])

        _ = submenu("文件", in: main, [
            item("新建笔记", #selector(newNote(_:)), "n", target: self),
            item("导入笔迹文件…", #selector(importNote(_:)), "o", target: self),
            .separator(),
            item("重命名…", #selector(renameNote(_:)), "r", [.command, .shift], target: self),
            item("复制这条笔记", #selector(duplicateNote(_:)), target: self),
            item("移到废纸篓…", #selector(trashNote(_:)), "\u{8}", [.command], target: self),
            .separator(),
            item("导出 PDF…", #selector(exportPDF(_:)), "e", target: self),
            item("导出 PNG 图片…", #selector(exportPNG(_:)), "e", [.command, .shift], target: self),
            item("导出可编辑笔迹文件…", #selector(exportArchive(_:)), target: self),
            .separator(),
            item("在访达中显示笔记文件夹", #selector(revealNotesFolder(_:)), target: self),
        ])

        // Nil-targeted: the text field handles these while editing, the
        // board otherwise.
        let editMenu = submenu("编辑", in: main, [
            item("撤销", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("复制一份", #selector(BoardTabView.duplicate(_:)), "d"),
            item("删除", #selector(NSText.delete(_:))),
            item("全选", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("清空这条笔记…", #selector(clearNote(_:)), target: self),
        ])
        _ = editMenu

        let toolMenu = submenu("工具", in: main, BoardTool.allCases.map { tool in
            let menuItem = item("\(tool.name)（按 \(tool.rawValue)）", #selector(selectTool(_:)), target: self)
            menuItem.tag = tool.rawValue
            return menuItem
        })
        toolMenu.addItem(.separator())
        let textHint = item("文字：按 T", nil)
        textHint.isEnabled = false
        toolMenu.addItem(textHint)
        let colorHint = item("换颜色：按 C（⇧C 反向）· 换粗细：按 W", nil)
        colorHint.isEnabled = false
        toolMenu.addItem(colorHint)
        toolMenu.addItem(.separator())
        for (title, tag) in [("笔尖一接触就书写", 1), ("轻触只显示位置，按下才书写", 0)] {
            let trigger = item(title, #selector(selectWritingTrigger(_:)), target: self)
            trigger.tag = tag
            toolMenu.addItem(trigger)
        }
        toolMenu.addItem(item("校准按压力度…", #selector(calibratePressure(_:)), target: self))
        toolMenu.addItem(.separator())
        let whole = item("橡皮擦除整笔", #selector(toggleWholeStrokeEraser(_:)), target: self)
        whole.state = defaults.bool(forKey: "eraseWholeStrokes") ? .on : .off
        toolMenu.addItem(whole)
        let smooth = item("修顺笔迹（减轻手抖）", #selector(toggleSmoothStrokes(_:)), target: self)
        smooth.state = (defaults.object(forKey: "smoothStrokes") as? Bool ?? true) ? .on : .off
        toolMenu.addItem(smooth)

        let paperItems = PaperStyle.allCases.map { paper -> NSMenuItem in
            let menuItem = item("纸张：" + paper.name, #selector(selectPaper(_:)), target: self)
            menuItem.representedObject = paper.rawValue
            return menuItem
        }
        let aim = item("手掌放下时预测落笔位置", #selector(togglePenAim(_:)), target: self)
        aim.state = (defaults.object(forKey: "showPenAim") as? Bool ?? true) ? .on : .off
        let camera = item("用 iPhone 摄像头显示悬停的笔尖", #selector(toggleCameraPen(_:)), target: self)
        camera.state = defaults.bool(forKey: "cameraPen.enabled") ? .on : .off
        let debug = item("在状态栏显示调试信息", #selector(toggleDebugInfo(_:)), target: self)
        debug.state = defaults.bool(forKey: "showDebugInfo") ? .on : .off
        _ = submenu("显示", in: main, paperItems + [
            .separator(),
            item("实际大小", #selector(actualSize(_:)), "0", target: self),
            item("放大", #selector(zoomIn(_:)), "=", target: self),
            item("缩小", #selector(zoomOut(_:)), "-", target: self),
            .separator(),
            item("显示 / 隐藏笔记列表", #selector(toggleSidebar(_:)), "s", [.command, .control], target: self),
            item("小窗：浮在所有应用上方（全局 ⌃⌥N）", #selector(toggleFloating(_:)), target: self),
            item("回到主窗口", #selector(showMainWindow(_:)), target: self),
            item("切换书写 / 指针模式（Esc）", #selector(toggleWriting(_:)), target: self),
            .separator(),
            aim,
            camera,
            item("摄像头对准…", #selector(alignCamera(_:)), target: self),
            .separator(),
            debug,
        ])

        let palm = item("防误触（只让一个触点落笔）", #selector(togglePalmRejection(_:)), "p", [.command, .shift], target: self)
        palm.state = (defaults.object(forKey: "palmRejection") as? Bool ?? true) ? .on : .off
        let savedHand = defaults.string(forKey: "palmHand") ?? PalmRejector.Hand.right.rawValue
        let hands = [("右手书写", PalmRejector.Hand.right), ("左手书写", .left)].map { title, hand -> NSMenuItem in
            let menuItem = item(title, #selector(selectHand(_:)), target: self)
            menuItem.representedObject = hand.rawValue
            menuItem.state = savedHand == hand.rawValue ? .on : .off
            return menuItem
        }
        let shape = item("按触点形状识别笔尖（需“输入监控”权限）", #selector(toggleContactSize(_:)), target: self)
        shape.state = (defaults.object(forKey: "palmUseContactSize") as? Bool ?? true) ? .on : .off
        let finger = item("也允许手指书写（防误触会变弱）", #selector(toggleAllowFinger(_:)), target: self)
        finger.state = defaults.bool(forKey: "palmAllowFinger") ? .on : .off
        let hint = item("笔尖长轴上限：书写时按 - / = 调整", nil)
        hint.isEnabled = false
        let recordHeader = item("录制触点数据（每项 20 秒）", nil)
        recordHeader.isEnabled = false
        let recordings = [
            ("① 只用笔写（手掌悬空）", "1-pen"),
            ("② 只放手掌（放下、滑动、抬起）", "2-palm"),
            ("③ 正常握笔书写", "3-write"),
            ("④ 只用手指写", "4-finger"),
            ("⑤ 双指拖动、缩放画布", "5-twofinger"),
        ].map { title, label -> NSMenuItem in
            let menuItem = item(title, #selector(recordTouches(_:)), target: self)
            menuItem.representedObject = label
            return menuItem
        }
        let continuous = item("持续记录书写时的触点数据（仅存本机）", #selector(toggleContinuousLog(_:)), target: self)
        continuous.state = TouchRecorder.shared.isContinuous ? .on : .off
        _ = submenu("防误触", in: main, [palm, .separator()] + hands + [
            .separator(), shape, finger, hint, .separator(),
            item("在无边记中手写（连接器，实验）", #selector(toggleFreeformConnector(_:)), target: self),
            .separator(), recordHeader,
        ] + recordings + [
            .separator(), continuous,
            item("在访达中显示触点记录", #selector(revealTouchLog(_:)), target: self),
        ])

        let windowMenu = submenu("窗口", in: main, [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("关闭", #selector(NSWindow.performClose(_:)), "w"),
        ])

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
