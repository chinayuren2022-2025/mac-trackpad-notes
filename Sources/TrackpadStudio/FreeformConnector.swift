import AppKit
import ApplicationServices

/// Drives Freeform (无边记) with the stylus: raw MultitouchSupport frames →
/// ConnectorCore (pen / palm / two-finger rules) → synthetic left-mouse
/// down / drag / up at the matching point of Freeform's front window.
///
/// While Freeform is frontmost and writing is on, an event tap swallows the
/// trackpad's own pointer events (moves, clicks, taps), so a resting palm can
/// neither move nor click anything; scroll / pinch events are let through only
/// while a two-finger gesture is recognised, so Freeform pans and zooms
/// natively. ⌃⌥⌘F toggles writing ⇄ normal mouse (e.g. to pick a tool).
/// Every other app is left untouched.
///
/// Needs Accessibility (post + filter events) and Input Monitoring (frames).
final class FreeformConnector {
    static let shared = FreeformConnector()
    static let targetBundleID = "com.apple.freeform"
    /// Tags our own synthetic events so the tap lets them through.
    private static let eventMarker: Int64 = 0x5452_4B50

    private(set) var isArmed = false
    /// ⌃⌥⌘F: writing (pen draws, pointer blocked) ⇄ mouse (everything passes).
    private(set) var isWriting = true
    var onStateChange: (() -> Void)?

    private var core = ConnectorCore()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Pen area on screen: global display coordinates, top-left origin.
    private var targetRect: CGRect?
    private var lastNavigationAt: TimeInterval = 0
    private let overlay = ConnectorOverlay()
    private var statusItem: NSStatusItem?
    private var workspaceObserver: NSObjectProtocol?
    private var refreshTimer: Timer?

    private init() {}

    var isTargetFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.targetBundleID
    }

    var isIntercepting: Bool { isArmed && isWriting && isTargetFrontmost }

    enum ArmError: Error {
        case accessibility
        case eventTap
    }

    func arm() -> Result<Void, ArmError> {
        guard !isArmed else { return .success(()) }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return .failure(.accessibility) }
        guard installTap() else { return .failure(.eventTap) }

        MultitouchReader.shared.start()
        multitouchConnectorTap = { [weak self] samples, now in
            self?.handle(samples, now: now)
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        isArmed = true
        isWriting = true
        installStatusItem()
        refresh()
        onStateChange?()
        return .success(())
    }

    func disarm() {
        guard isArmed else { return }
        post(core.reset())
        multitouchConnectorTap = nil
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        tapSource = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        overlay.hide()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        isArmed = false
        onStateChange?()
    }

    func toggleWriting() {
        guard isArmed else { return }
        isWriting.toggle()
        if !isWriting { post(core.reset()) }
        refresh()
        onStateChange?()
    }

    // MARK: - Frames → mouse

    private func handle(_ samples: [MTFingerSample], now: TimeInterval) {
        guard isIntercepting, targetRect != nil else {
            if core.isPenDown { post(core.reset()) }
            return
        }
        let defaults = UserDefaults.standard
        core.rejector.hand = PalmRejector.Hand(rawValue: defaults.string(forKey: "palmHand") ?? "") ?? .right
        let maxMajor = defaults.double(forKey: "penMaxMajor")
        core.rejector.penMaxMajor = maxMajor > 0 ? maxMajor : 8.0
        core.rejector.allowFinger = defaults.bool(forKey: "palmAllowFinger")

        let contacts = samples.compactMap { sample -> ConnectorContact? in
            guard (3...6).contains(sample.state), sample.size > 0.05 else { return nil }
            return ConnectorContact(
                id: sample.id,
                pos: sample.pos,
                shape: .init(size: sample.size, majorAxis: sample.majorAxis, minorAxis: sample.minorAxis),
                touching: sample.state <= 4
            )
        }
        let actions = core.process(contacts, now: now)
        if core.navigating { lastNavigationAt = now }
        if actions.contains(where: { if case .down = $0 { return true }; return false }) {
            refreshTarget()   // the window may have moved since the last stroke
        }
        post(actions)
    }

    private func post(_ actions: [ConnectorAction]) {
        guard let rect = targetRect, !actions.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for action in actions {
            let type: CGEventType
            let point: CGPoint
            switch action {
            case let .down(p): type = .leftMouseDown; point = p
            case let .drag(p): type = .leftMouseDragged; point = p
            case let .up(p): type = .leftMouseUp; point = p
            }
            let screen = CGPoint(
                x: rect.minX + min(1, max(0, point.x)) * rect.width,
                y: rect.minY + (1 - min(1, max(0, point.y))) * rect.height
            )
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: screen, mouseButton: .left
            ) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            if type != .leftMouseUp { event.setDoubleValueField(.mouseEventPressure, value: 1) }
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Target window

    private func refresh() {
        refreshTarget()
        updateStatusItem()
    }

    private func refreshTarget() {
        guard isIntercepting, let app = NSWorkspace.shared.frontmostApplication else {
            targetRect = nil
            overlay.hide()
            return
        }
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        // Front-to-back order: the first normal-layer window of Freeform that
        // is big enough to be a board (skips popovers and panels).
        let bounds = windows.lazy.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 300, rect.height > 250 else { return nil }
            return rect
        }.first
        guard let window = bounds else {
            targetRect = nil
            overlay.hide()
            return
        }
        // Below the title/toolbar strip, with a small margin; keep the pad's
        // aspect so handwriting is not stretched.
        let content = CGRect(x: window.minX + 16, y: window.minY + 68,
                             width: window.width - 32, height: window.height - 84)
        let pad = DeviceSizeStore.recalled ?? CGSize(width: 1.6, height: 1)
        let aspect = pad.width / max(pad.height, 0.01)
        var width = content.width
        var height = width / aspect
        if height > content.height {
            height = content.height
            width = height * aspect
        }
        let rect = CGRect(x: content.midX - width / 2, y: content.midY - height / 2,
                          width: width, height: height)
        if rect != targetRect {
            targetRect = rect
        }
        overlay.show(rect)
    }

    // MARK: - Event tap

    private func installTap() -> Bool {
        let rawTypes: [UInt32] = [
            CGEventType.mouseMoved.rawValue,
            CGEventType.leftMouseDown.rawValue, CGEventType.leftMouseUp.rawValue,
            CGEventType.leftMouseDragged.rawValue,
            CGEventType.rightMouseDown.rawValue, CGEventType.rightMouseUp.rawValue,
            CGEventType.rightMouseDragged.rawValue,
            CGEventType.otherMouseDown.rawValue, CGEventType.otherMouseUp.rawValue,
            CGEventType.otherMouseDragged.rawValue,
            CGEventType.scrollWheel.rawValue,
            CGEventType.keyDown.rawValue,
            18, 19, 20, 29, 30, 31, 32, 34,   // rotate, begin/end gesture, gesture, magnify, swipe, smart magnify, pressure
        ]
        let mask = rawTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: connectorTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    /// true = let the event through.
    fileprivate func shouldPass(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker { return true }

        if type == .keyDown {
            let keyF: Int64 = 3
            let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            if event.getIntegerValueField(.keyboardEventKeycode) == keyF,
               flags == [.maskControl, .maskAlternate, .maskCommand] {
                toggleWriting()
                return false
            }
            return true
        }

        guard isIntercepting else { return true }
        switch type.rawValue {
        case CGEventType.scrollWheel.rawValue, 18, 19, 20, 29, 30, 31, 32:
            // Two-finger pan / pinch reach Freeform; a short tail lets the
            // gesture's own end events and momentum through.
            return core.navigating || ProcessInfo.processInfo.systemUptime - lastNavigationAt < 0.3
        default:
            return false
        }
    }

    // MARK: - Menu bar status

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "", action: #selector(menuToggleWriting), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let off = NSMenuItem(title: "关闭无边记连接器", action: #selector(menuDisarm), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let statusItem else { return }
        let writing = isWriting
        statusItem.button?.title = writing ? "✎ 书写" : "✎ 鼠标"
        statusItem.button?.toolTip = "无边记连接器：⌃⌥⌘F 切换书写 / 鼠标"
        statusItem.menu?.items.first?.title = writing
            ? "切换到鼠标模式（⌃⌥⌘F）"
            : "切换到书写模式（⌃⌥⌘F）"
    }

    @objc private func menuToggleWriting() { toggleWriting() }
    @objc private func menuDisarm() { disarm() }
}

private func connectorTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let connector = Unmanaged<FreeformConnector>.fromOpaque(refcon).takeUnretainedValue()
    return connector.shouldPass(type, event) ? Unmanaged.passUnretained(event) : nil
}

/// Click-through outline of the pen area on top of Freeform, so the hand
/// knows where on the pad the board is.
final class ConnectorOverlay {
    private var panel: NSPanel?
    private var shownRect: CGRect?

    func show(_ rect: CGRect) {
        guard rect != shownRect || panel?.isVisible != true else { return }
        shownRect = rect
        // Global display space (top-left origin) → Cocoa (bottom-left, primary screen).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        let panel = self.panel ?? makePanel()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        shownRect = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = OutlineView()
        return panel
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
            path.lineWidth = 1.5
            path.setLineDash([6, 5], count: 2, phase: 0)
            NSColor.systemBlue.withAlphaComponent(0.45).setStroke()
            path.stroke()
        }
    }
}
