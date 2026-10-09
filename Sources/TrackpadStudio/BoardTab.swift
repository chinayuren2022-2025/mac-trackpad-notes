import AppKit
import CoreGraphics

final class BoardTabView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    /// Zen mode = distraction-free drawing: trackpad touches drive the app
    /// cursor, the system pointer is frozen (and hidden) so the finger owns the
    /// board. Pointer mode hands the machine back to macOS.
    private enum InteractionMode {
        case zen
        case pointer

        var badge: String {
            switch self {
            case .zen: return "书写"
            case .pointer: return "指针"
            }
        }
    }

    private struct Draft {
        let tool: BoardTool
        let start: CGPoint
        var current: CGPoint
        /// Ink samples (pen, highlighter) or the lasso outline.
        var strokeSamples: [BoardStrokeSample]
        var width: CGFloat
        let color: NSColor
        /// Lasso tool: this gesture drags the current selection.
        var movesSelection = false
    }

    /// Previous-frame state of a raw two-finger gesture, kept in NORMALIZED pad
    /// coordinates. Storing view-space points here would silently corrupt the
    /// gesture whenever the pad rect changed mid-gesture (device-size discovery,
    /// window resize) — the baseline would be expressed in a rect that no
    /// longer exists.
    private struct TwoFingerBaseline {
        var centroid: CGPoint
        var spread: CGFloat
    }

    private let model = BoardModel()
    /// The note's content changed (autosave hook).
    var onContentChange: (() -> Void)?
    /// Writing (zen) mode switched on or off; the sidebar only takes clicks
    /// in pointer mode, so a hard press while writing can't open another note.
    var onModeChange: ((Bool) -> Void)?
    /// true: any pen contact writes. false: a light touch only shows where
    /// the pen is; ink needs a press (a trackpad click, or the calibrated
    /// pressure from `pressureGate`).
    var drawOnContact = UserDefaults.standard.object(forKey: "drawOnContact") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(drawOnContact, forKey: "drawOnContact")
            pressureInking = false
            needsDisplay = true
        }
    }
    /// Pressure thresholds for press-to-write without a full click; nil
    /// until calibrated (then only a click writes).
    private(set) var pressureGate = PressureGate.load()
    private var pressureInking = false
    private enum PressCalibration {
        case light([Double])
        case waitingForLift(light: [Double])
        case firm(light: [Double], [Double])
    }
    private var pressCalibration: PressCalibration?
    private static let calibrationSamples = 150
    /// Palm rejection: only one elected contact ever inks; everything else is
    /// shown as a red ghost and ignored.
    var palmRejectionEnabled = UserDefaults.standard.object(forKey: "palmRejection") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(palmRejectionEnabled, forKey: "palmRejection")
            palmRejector.reset()
            navigatingIDs.removeAll()
            rejectedTouches = []
            needsDisplay = true
        }
    }
    var palmHand: PalmRejector.Hand {
        get { palmRejector.hand }
        set {
            palmRejector.hand = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "palmHand")
            penAim = PenAim.load(hand: newValue)
            needsDisplay = true
        }
    }
    /// Before the pen touches, mark where it is expected to land (learned
    /// from where it lands relative to the resting palm).
    var showPenAim = UserDefaults.standard.object(forKey: "showPenAim") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(showPenAim, forKey: "showPenAim")
            needsDisplay = true
        }
    }
    private lazy var penAim = PenAim.load(hand: palmHand)
    /// Centroid of the contacts judged to be the writing hand's palm.
    private var palmAnchor: CGPoint?
    private var lastPenID: Int?
    /// Contact-shape pen detection via the private MultitouchSupport reader.
    var useContactSize = UserDefaults.standard.object(forKey: "palmUseContactSize") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useContactSize, forKey: "palmUseContactSize")
            if useContactSize {
                MultitouchReader.shared.start()
            } else if !FreeformConnector.shared.isArmed {
                MultitouchReader.shared.stop()
            }
            needsDisplay = true
        }
    }
    private var palmRejector: PalmRejector = {
        var rejector = PalmRejector()
        rejector.hand = PalmRejector.Hand(
            rawValue: UserDefaults.standard.string(forKey: "palmHand") ?? ""
        ) ?? .right
        return rejector
    }()
    /// Longest ellipse axis (mm) still accepted as a pen tip; `-` / `=` tune it.
    private var penMaxMajor: Double = {
        let stored = UserDefaults.standard.double(forKey: "penMaxMajor")
        return stored > 0 ? stored : 8.0
    }() {
        didSet { UserDefaults.standard.set(penMaxMajor, forKey: "penMaxMajor") }
    }
    var allowFinger = UserDefaults.standard.bool(forKey: "palmAllowFinger") {
        didSet {
            UserDefaults.standard.set(allowFinger, forKey: "palmAllowFinger")
            palmRejector.reset()
        }
    }
    /// Developer readouts (contact size, pen shape) in the status strip.
    var showDebugInfo = UserDefaults.standard.bool(forKey: "showDebugInfo") {
        didSet {
            UserDefaults.standard.set(showDebugInfo, forKey: "showDebugInfo")
            needsDisplay = true
        }
    }
    /// The eraser removes whole strokes instead of only the ink it touches.
    var eraseWholeStrokes = UserDefaults.standard.bool(forKey: "eraseWholeStrokes") {
        didSet { UserDefaults.standard.set(eraseWholeStrokes, forKey: "eraseWholeStrokes") }
    }
    /// Shape of the elected pen this frame, for the status readout.
    private var penShape: PalmRejector.ContactShape?
    /// Two finger-shaped contacts currently driving pan + zoom under palm rejection.
    private var navigatingIDs: Set<Int> = []
    /// When one navigating finger dropped out (the pad loses a light contact
    /// for a frame or two mid-drag); the gesture is held briefly, not ended.
    private var navigationLostAt: TimeInterval?
    /// Contacts the rejector refused this frame, render-only.
    private var rejectedTouches: [TouchSample] = []
    private let captureView = TouchCaptureView()

    // MARK: Ink palette

    /// White paper, near-black default ink, blue UI accent.
    static let palette: [(name: String, color: NSColor)] = [
        ("黑", NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)),
        ("蓝", NSColor(srgbRed: 0.06, green: 0.36, blue: 0.86, alpha: 1)),
        ("红", NSColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 1)),
        ("绿", NSColor(srgbRed: 0.09, green: 0.58, blue: 0.30, alpha: 1)),
        ("黄", NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1)),
    ]
    /// Canvas-unit widths: fine / medium (the old fixed 2) / bold.
    static let penWidths: [CGFloat] = [1.4, 2, 3.2]
    static let highlighterWidths: [CGFloat] = [8, 13, 20]
    private let accentColor = NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.95, alpha: 1)
    private let paperColor = NSColor.white
    /// Default ink of the earlier dark theme; notes written with it are shown
    /// in black so they stay readable on white paper.
    private static let legacyInk = NSColor(calibratedRed: 0.55, green: 0.78, blue: 1.0, alpha: 1)

    private static func storedIndex(_ key: String, _ fallback: Int, count: Int) -> Int {
        let value = UserDefaults.standard.object(forKey: key) as? Int ?? fallback
        return (0..<count).contains(value) ? value : fallback
    }
    private var penColorIndex = storedIndex("penColor", 0, count: palette.count) {
        didSet { UserDefaults.standard.set(penColorIndex, forKey: "penColor") }
    }
    private var highlighterColorIndex = storedIndex("highlighterColor", 4, count: palette.count) {
        didSet { UserDefaults.standard.set(highlighterColorIndex, forKey: "highlighterColor") }
    }
    private var penWidthIndex = storedIndex("penWidth", 1, count: penWidths.count) {
        didSet { UserDefaults.standard.set(penWidthIndex, forKey: "penWidth") }
    }
    private var highlighterWidthIndex = storedIndex("highlighterWidth", 1, count: highlighterWidths.count) {
        didSet { UserDefaults.standard.set(highlighterWidthIndex, forKey: "highlighterWidth") }
    }

    /// Pen color: shapes and text use it too.
    private var inkColor: NSColor { Self.palette[penColorIndex].color }
    private var inkWidth: CGFloat { Self.penWidths[penWidthIndex] }
    /// The palette slot the swatches show and change: the highlighter has its own.
    private var activeColorIndex: Int {
        get { currentTool == .highlighter ? highlighterColorIndex : penColorIndex }
        set {
            if currentTool == .highlighter { highlighterColorIndex = newValue } else { penColorIndex = newValue }
        }
    }
    private var activeWidthIndex: Int {
        get { currentTool == .highlighter ? highlighterWidthIndex : penWidthIndex }
        set {
            if currentTool == .highlighter { highlighterWidthIndex = newValue } else { penWidthIndex = newValue }
        }
    }
    private func inkColor(for tool: BoardTool) -> NSColor {
        tool == .highlighter
            ? Self.palette[highlighterColorIndex].color.withAlphaComponent(InkRenderer.highlighterAlpha)
            : inkColor
    }
    private func inkWidth(for tool: BoardTool) -> CGFloat {
        tool == .highlighter ? Self.highlighterWidths[highlighterWidthIndex] : inkWidth
    }

    private var currentTool: BoardTool = .pen
    /// Active touches only — every gesture rule counts off this array, so a
    /// resting thumb or palm can never reach the state machine.
    private var currentTouches: [TouchSample] = []
    /// Resting touches, render-only.
    private var restingTouches: [TouchSample] = []
    // Seeded from the last device we saw, so the pad rect is already the right
    // shape at launch instead of snapping on the first touch.
    private var currentDeviceSize = DeviceSizeStore.recalled
        ?? CGSize(width: 1.6, height: 1)
    private var matchedFinger: MTFingerSample?
    private var currentCursorViewPoint: CGPoint?
    private var lastCursorViewPoint: CGPoint?

    private var activeDraft: Draft?
    /// Eraser gesture state: last canvas point, and whether this gesture has
    /// already recorded its undo step.
    private var eraserLastPoint: CGPoint?
    private var eraserGestureErased = false
    /// Eraser reach in view points (scaled to canvas by the current zoom).
    private let eraserRadius: CGFloat = 10

    // MARK: Selection

    /// Lassoed elements. Indices are only meaningful for the model revision
    /// they were taken at; any other edit (undo, erase…) drops the selection.
    private var selection = IndexSet()
    private var selectionRevision = -1
    /// Live drag of the selection, applied to the model on release.
    private var selectionOffset: CGPoint = .zero
    private var currentSelection: IndexSet {
        model.revision == selectionRevision ? selection : []
    }

    private var isMouseDown = false
    private var currentPressure: CGFloat = 0
    private var drawingSuppressedUntilRelease = false

    private var textEditor: NSTextField?
    private var textEditorCanvasOrigin: CGPoint?
    private var isEndingTextEdit = false

    private var twoFingerBaseline: TwoFingerBaseline?
    private var isTwoFingerNavigating = false
    private var isThreeFingerDrawing = false
    /// Identity of the finger acting as the pen for the current 3-finger
    /// gesture. Locked at gesture start, never re-elected mid-gesture.
    private var penFingerID: Int?

    private var interactionMode: InteractionMode = .zen {
        didSet {
            if interactionMode != oldValue { onModeChange?(interactionMode == .zen) }
        }
    }
    var isWriting: Bool { interactionMode == .zen }
    private var cursorFrozen = false
    private var cursorTrackingArea: NSTrackingArea?
    private lazy var transparentCursor = Self.makeTransparentCursor()
    private var pollTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    /// Set when zen was interrupted by losing key focus, so it can be restored.
    private var resumeZenOnKey = false
    /// Transient status message (paste, export…).
    private var flashText: String?

    private let statusHeight: CGFloat = 34
    private let toolbarWidth: CGFloat = 56
    /// 36 pt per tool, shrinking to 28 so the toolbar fits a small window.
    private var toolbarItemHeight: CGFloat {
        let fixed = 6 + sectionGap * 2 + swatchRowHeight * CGFloat(swatchRows) + 4 + widthRowHeight + 6
        let available = bounds.height - statusHeight - edgeInset * 2 - fixed
        return min(36, max(28, available / CGFloat(BoardTool.allCases.count + 1)))
    }
    private let sectionGap: CGFloat = 12
    private let swatchRowHeight: CGFloat = 24
    private let widthRowHeight: CGFloat = 24
    private let edgeInset: CGFloat = 12
    /// On-screen point size of text at the moment it is typed.
    private let textBaseFontSize: CGFloat = 16
    /// Offset from the text editor's frame origin to where its glyphs actually sit.
    private let textEditorTextInset = CGSize(width: 2, height: 5)

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)

        model.onChange = { [weak self] in
            self?.onContentChange?()
        }

        wantsLayer = true
        canvasView.frame = bounds
        canvasView.autoresizingMask = [.width, .height]
        addSubview(canvasView)

        captureView.frame = bounds
        captureView.autoresizingMask = [.width, .height]
        captureView.onEvent = { [weak self] event in
            guard let self else { return }
            if case let .touches(touches) = event, self.usesRawTouches {
                guard self.rawStreamLooksDead(touches) else { return }
                // Raw frames stopped (missed wake, device reset): get a fresh
                // device and let the system's events drive the board meanwhile.
                MultitouchReader.shared.restart()
            }
            self.handle(event)
        }
        MultitouchReader.shared.onFrame = { [weak self] fingers in
            self?.handleRawFrame(fingers)
        }
        addSubview(captureView)

        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        addSubview(overlayView)

        registerForDraggedTypes([.fileURL, .png, .tiff, .pdf])

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            self?.pollMultitouch()
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    required init?(coder: NSCoder) {
        fatalError("BoardTabView does not support NSCoder initialization")
    }

    deinit {
        pollTimer?.invalidate()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        restoreCursorAssociation(force: true)
        NSCursor.arrow.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservation()

        if window == nil {
            enterPointerMode()
        } else {
            enterZenMode()
            window?.makeFirstResponder(captureView)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .cursorUpdate,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        cursorTrackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func cursorUpdate(with event: NSEvent) {
        if interactionMode == .zen, window?.isKeyWindow == true {
            transparentCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        applySystemCursorForCurrentMode()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func layout() {
        super.layout()
        refreshCanvasCache()
        positionTextEditor()
    }

    // MARK: - Note document

    /// Serialized note. Does not touch an in-progress stroke, so autosave can
    /// run mid-writing.
    func noteData() throws -> Data {
        try model.documentData()
    }

    /// Commits a half-typed text and a stroke still under the pen (before the
    /// note is switched away from or the app quits).
    func commitPendingEdits() {
        commitTextEditing()
        finishActiveDraft()
    }

    /// Shows a note; nil data starts a blank note on `paper`.
    func loadNote(_ data: Data?, paper: PaperStyle) throws {
        cancelTextEditing()
        cancelActiveDraft()
        clearSelection()
        if let data {
            try model.loadDocument(data)
        } else {
            try model.loadDocument(BoardModel().documentData())
            model.paper = paper
        }
        needsDisplay = true
    }

    var paper: PaperStyle {
        get { model.paper }
        set {
            model.paper = newValue
            needsDisplay = true
        }
    }

    var isEmpty: Bool { model.isEmpty }

    /// Whole-note rendering: the content's bounds plus a margin, on paper.
    private func renderNote(into context: CGContext, size: CGSize, content: CGRect) {
        let renderer = InkRenderer.fitting(content, into: CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        renderer.drawPaper(model.paper, in: CGRect(origin: .zero, size: size), color: paperColor)
        model.elements.forEach { renderer.draw(displayed($0)) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private var exportBounds: CGRect? {
        let content = model.contentBounds
        guard !content.isNull, content.width.isFinite else { return nil }
        return content.insetBy(dx: -40, dy: -40)
    }

    /// Small preview for the notes list (PNG); nil for an empty note.
    func thumbnailPNG(maxSize: CGSize) -> Data? {
        guard let content = exportBounds else { return nil }
        // Same aspect as the list cell, so every thumbnail fills its frame.
        let aspect = maxSize.width / maxSize.height
        var box = content
        if box.width / box.height < aspect {
            box = box.insetBy(dx: -(box.height * aspect - box.width) / 2, dy: 0)
        } else {
            box = box.insetBy(dx: 0, dy: -(box.width / aspect - box.height) / 2)
        }
        let scale: CGFloat = 2
        let w = Int(maxSize.width * scale), h = Int(maxSize.height * scale)
        guard let context = Self.bitmapContext(width: w, height: h) else { return nil }
        renderNote(into: context, size: CGSize(width: w, height: h), content: box)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Vector PDF of the whole note, one page sized to the content.
    func pdfData() -> Data? {
        guard let content = exportBounds else { return nil }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: content.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        renderNote(into: context, size: content.size, content: content)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Whole note as a PNG at 2× (sharp on Retina and in print).
    func pngData() -> Data? {
        guard let content = exportBounds else { return nil }
        let scale: CGFloat = 2
        let w = Int(content.width * scale), h = Int(content.height * scale)
        guard w * h < 400_000_000, let context = Self.bitmapContext(width: w, height: h) else { return nil }
        renderNote(into: context, size: CGSize(width: w, height: h), content: content)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    /// Paper and committed ink rendered once at backing resolution and handed
    /// to Core Animation as layer contents: composited on the GPU, so a full
    /// page costs nothing per frame. Rebuilt when the view state changes; a
    /// single appended element is drawn into it incrementally. The selection
    /// is left out — the overlay draws it, so dragging it costs no rebuild.
    private struct CanvasCacheKey: Equatable {
        let size: CGSize
        let zoom: CGFloat
        let pan: CGPoint
        let scale: CGFloat
        let excluded: IndexSet
    }
    private var canvasCache: (context: CGContext, key: CanvasCacheKey, revision: Int)?
    private let canvasView = CanvasCacheView()
    private lazy var overlayView = OverlayView(board: self)

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            guard newValue else { return }
            overlayView.needsDisplay = true
            refreshCanvasCache()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshCanvasCache()
    }

    private var canvasRebuildWork: DispatchWorkItem?

    func refreshCanvasCache(forceRebuild: Bool = false) {
        let scale = window?.backingScaleFactor ?? 2
        let key = CanvasCacheKey(
            size: bounds.size, zoom: model.zoom, pan: model.pan, scale: scale, excluded: currentSelection
        )
        guard forceRebuild || canvasCache?.key != key || canvasCache?.revision != model.revision else { return }

        // Pan / zoom only: move the cached image on the GPU and re-render it
        // sharp once the gesture settles. canvasToView is c + (p - c)·z + pan,
        // so the old image maps by scale s = z/z0 about the view center.
        if !forceRebuild, let cache = canvasCache, cache.revision == model.revision,
           cache.key.size == key.size, cache.key.scale == key.scale, cache.key.excluded == key.excluded {
            let s = model.zoom / cache.key.zoom
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            canvasView.setImageTransform(CGAffineTransform(
                a: s, b: 0, c: 0, d: s,
                tx: c.x - s * c.x + model.pan.x - s * cache.key.pan.x,
                ty: c.y - s * c.y + model.pan.y - s * cache.key.pan.y
            ))
            canvasRebuildWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshCanvasCache(forceRebuild: true) }
            canvasRebuildWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        canvasRebuildWork?.cancel()
        canvasRebuildWork = nil

        let renderer = model.renderer(in: bounds)
        if !forceRebuild, let cache = canvasCache, cache.key == key,
           model.revision == cache.revision + 1, model.lastChangeWasAppend,
           let last = model.elements.last {
            render(into: cache.context) { renderer.draw(displayed(last)) }
            canvasCache?.revision = model.revision
        } else if !forceRebuild, let cache = canvasCache, cache.key == key,
                  model.revision == cache.revision + 1, let dirty = model.lastChangeDirtyRect {
            // Eraser step: repaint only the area it touched, snapped to whole
            // device pixels so the patch has no seam.
            let pixels = CGRect(x: 0, y: 0, width: cache.context.width, height: cache.context.height)
            let patch = renderer.rect(dirty)
                .applying(CGAffineTransform(scaleX: scale, y: scale)).integral.intersection(pixels)
            if !patch.isNull, !patch.isEmpty {
                let clip = patch.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
                let excluded = key.excluded
                render(into: cache.context) {
                    cache.context.saveGState()
                    cache.context.clip(to: clip)
                    cache.context.clear(clip)
                    renderer.drawPaper(model.paper, in: bounds, color: paperColor)
                    let canvasClip = CGRect(origin: renderer.canvasPoint(clip.origin), size: .zero)
                        .union(CGRect(origin: renderer.canvasPoint(CGPoint(x: clip.maxX, y: clip.maxY)), size: .zero))
                    for (i, element) in model.elements.enumerated()
                    where !excluded.contains(i) && element.bounds.insetBy(dx: -16, dy: -16).intersects(canvasClip) {
                        renderer.draw(displayed(element))
                    }
                    cache.context.restoreGState()
                }
            }
            canvasCache?.revision = model.revision
        } else {
            let width = Int((bounds.width * scale).rounded(.up))
            let height = Int((bounds.height * scale).rounded(.up))
            guard let context = Self.bitmapContext(width: width, height: height) else { return }
            context.scaleBy(x: scale, y: scale)
            render(into: context) {
                renderer.drawPaper(model.paper, in: bounds, color: paperColor)
                for (i, element) in model.elements.enumerated() where !key.excluded.contains(i) {
                    renderer.draw(displayed(element))
                }
            }
            canvasCache = (context, key, model.revision)
        }
        canvasView.image = canvasCache?.context.makeImage()
        canvasView.setImageTransform(.identity)
    }

    private func render(into context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Everything above the cached canvas; drawn by the transparent overlay.
    fileprivate func drawOverlays() {
        drawSelection()
        drawActiveDraft()
        drawEmptyStateHint()
        drawTrackpadOverlay()
        drawTouchMarkers()
        drawPenAim()
        drawToolbar()
        drawCursor()
        drawStatusStrip()
    }

    /// Fills the board with strokes replayed from a touch recording (tiled
    /// `copies` times), then times full redraws. Prints ms per frame.
    func runRenderBenchmark(recording: URL, copies: Int) {
        guard let text = try? String(contentsOf: recording, encoding: .utf8) else { return }
        var strokes: [[CGPoint]] = []
        var current: [CGPoint] = []
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "ns",
                  let touches = obj["touches"] as? [[String: Any]] else { continue }
            let active = touches.filter { $0["resting"] as? Bool != true }
            if active.count == 1, let x = active[0]["x"] as? Double, let y = active[0]["y"] as? Double {
                current.append(CGPoint(x: x, y: y))
            } else if !current.isEmpty {
                strokes.append(current)
                current = []
            }
        }
        if !current.isEmpty { strokes.append(current) }

        let pad = trackpadRect
        let side = Int(ceil(sqrt(Double(copies))))
        var samples = 0
        for copy in 0..<copies {
            let scale = 1 / CGFloat(side)
            let origin = CGPoint(x: CGFloat(copy % side) * scale, y: CGFloat(copy / side) * scale)
            for stroke in strokes {
                let points = stroke.map { p in
                    model.viewToCanvas(
                        TrackpadGeometry.map(
                            CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale),
                            into: pad
                        ),
                        in: bounds
                    )
                }
                samples += points.count
                model.append(.stroke(samples: points.map { BoardStrokeSample(point: $0, width: inkWidth) }, color: inkColor))
            }
        }

        guard let overlayRep = overlayView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        func time(_ runs: Int, _ before: () -> Void, _ body: () -> Void) -> Double {
            var total = 0.0
            for _ in 0..<runs {
                before()
                let start = CFAbsoluteTimeGetCurrent()
                body()
                total += CFAbsoluteTimeGetCurrent() - start
            }
            return total * 1000 / Double(runs)
        }
        let longest = strokes.max { $0.count < $1.count } ?? []
        let draftPoints = longest.map { model.viewToCanvas(TrackpadGeometry.map($0, into: pad), in: bounds) }
        activeDraft = Draft(tool: .pen, start: draftPoints.first ?? .zero, current: draftPoints.last ?? .zero,
                            strokeSamples: draftPoints.map { BoardStrokeSample(point: $0, width: inkWidth) },
                            width: inkWidth, color: inkColor)
        refreshCanvasCache()
        // Per frame while writing: only the overlay (live stroke + chrome) redraws.
        let frame = time(20, {}) { overlayView.cacheDisplay(in: bounds, to: overlayRep) }
        activeDraft = nil
        let append = time(10, {
            model.append(.stroke(samples: draftPoints.map { BoardStrokeSample(point: $0, width: inkWidth) }, color: inkColor))
        }) { refreshCanvasCache() }
        var flip: CGFloat = 1
        let panFrame = time(10, {
            flip = -flip
            model.pan(by: CGPoint(x: flip, y: 0))
        }) { refreshCanvasCache() }
        let rebuild = time(5, {}) { refreshCanvasCache(forceRebuild: true) }
        // Lasso-selecting half the board, then one drag frame of the selection.
        let half = IndexSet(0..<(model.elements.count / 2))
        selection = half
        selectionRevision = model.revision
        let select = time(1, {}) { refreshCanvasCache() }
        selectionOffset = CGPoint(x: 5, y: 5)
        let grab = time(1, {}) { overlayView.cacheDisplay(in: bounds, to: overlayRep) }
        let moveFrame = time(10, { selectionOffset.x += 1 }) { overlayView.cacheDisplay(in: bounds, to: overlayRep) }
        clearSelection()
        let pdf = time(1, {}) { _ = pdfData() }
        // Partial eraser dragged along the ink of a few strokes, one step per frame.
        var path: [CGPoint] = []
        for element in model.elements.suffix(model.elements.count / 2).prefix(8) {
            if case let .stroke(samples, _) = element { path += samples.map(\.point) }
        }
        var step = 0
        var erased = 0
        let eraseFrame = time(min(60, max(1, path.count - 1)), {}) {
            if path.count > 1, model.erase(from: path[step], to: path[step + 1],
                                           radius: eraserRadius, partial: true, recordingUndo: false) { erased += 1 }
            step += 1
            refreshCanvasCache()
        }
        print(String(format: "bench: %d strokes, %d samples | live-stroke frame %.2f ms (draft %d pts) | stroke added %.2f ms | drag frame %.2f ms | settle rebuild %.1f ms | select half %.1f ms | grab %.1f ms | move-selection frame %.1f ms | pdf export %.0f ms | eraser frame %.2f ms (%d hits)",
                     model.elements.count, samples, frame, draftPoints.count, append, panFrame, rebuild, select, grab, moveFrame, pdf, eraseFrame, erased))
        // The patched cache must match a full repaint pixel for pixel (±1 for antialiasing).
        if let patched = canvasCache?.context.makeImage(),
           let patchedData = patched.dataProvider?.data as Data? {
            refreshCanvasCache(forceRebuild: true)
            if let full = canvasCache?.context.makeImage(), let fullData = full.dataProvider?.data as Data? {
                var off = 0
                for (x, y) in zip(patchedData, fullData) where abs(Int(x) - Int(y)) > 1 { off += 1 }
                print("bench: eraser patch vs full repaint: \(off) differing bytes of \(fullData.count)")
            }
        }
        model.onChange = nil   // lets --bench quit without saving the stress board
    }

    /// Seeds a small demo note (the --snapshot screenshot mode in AppShell;
    /// never called during normal interaction).
    func seedDemoContent() {
        let blue = Self.palette[1].color, red = Self.palette[2].color, black = Self.palette[0].color
        var wave: [BoardStrokeSample] = []
        for i in 0...60 {
            let t = CGFloat(i) / 60
            wave.append(BoardStrokeSample(point: CGPoint(x: 330 + t * 540, y: 300 + sin(t * .pi * 3) * 42), width: 2))
        }
        model.append(.stroke(samples: wave, color: black))
        let mark = (0...10).map { i in
            BoardStrokeSample(point: CGPoint(x: 360 + CGFloat(i) * 22, y: 410 + CGFloat(i % 2)), width: 13)
        }
        model.append(.stroke(samples: mark, color: Self.palette[4].color.withAlphaComponent(InkRenderer.highlighterAlpha)))
        model.append(.text(origin: CGPoint(x: 366, y: 400), string: "触控板手写笔记", fontSize: 22, color: black))
        model.append(.ellipse(rect: CGRect(x: 770, y: 470, width: 88, height: 88), width: 2, color: red))
        model.append(.rectangle(rect: CGRect(x: 356, y: 452, width: 168, height: 104), width: 2, color: blue))
        model.append(.arrow(start: CGPoint(x: 640, y: 560), end: CGPoint(x: 540, y: 520), width: 2, color: blue))
        needsDisplay = true
    }

    // MARK: - Input

    private func handle(_ event: InputEvent) {
        switch event {
        case let .touches(touches):
            holdPointerInBackground()
            if palmRejectionEnabled, interactionMode == .zen {
                handlePalmFiltered(touches)
            } else {
                palmRejector.reset()
                rejectedTouches = []
                palmAnchor = nil
                TouchRecorder.shared.recordTouches(
                    touches, pen: nil, rejected: [], sizes: rawContactSizes(for: touches)
                )
                handleTouches(touches)
            }

        case let .pressure(pressure, _):
            // Pressure only drives stroke width now — deep press does nothing.
            currentPressure = min(1, max(0, CGFloat(pressure)))
            if interactionMode == .zen {
                updateSingleTouchInteraction()
            }
            needsDisplay = true

        case let .click(down, locationInView):
            handleClick(down: down, location: locationInView)

        case .drag:
            break

        case let .magnify(delta):
            // Zen mode navigates from raw two-finger touches instead — applying
            // the system gesture too would double-count it.
            guard interactionMode == .pointer else { return }
            model.zoom(by: max(0.01, 1 + CGFloat(delta)), in: bounds)
            positionTextEditor()
            needsDisplay = true

        case let .scroll(dx, dy, _, _):
            guard interactionMode == .pointer else { return }
            // scrollingDelta is expressed for a y-DOWN content system and
            // already carries the user's natural-scroll preference. This view
            // is y-up, so Y (and only Y) needs negating for the content to
            // follow the fingers. X is already correct.
            model.pan(by: CGPoint(x: CGFloat(dx), y: -CGFloat(dy)))
            positionTextEditor()
            needsDisplay = true

        case .rotate:
            break

        case let .key(chars, keyCode, modifiers):
            handleKey(chars: chars, keyCode: keyCode, modifiers: modifiers)
        }
    }

    /// The mini window over another app (a full-screen one): the system's
    /// touch events reach the panel only now and then there, so the private
    /// reader's frames (the same contacts, independent of focus and pointer)
    /// drive the board instead.
    private var usesRawTouches: Bool {
        interactionMode == .zen
            && MultitouchReader.shared.hasDeliveredFrames
            && window is FloatingNotePanel
            && window?.isKeyWindow == true
            && NSWorkspace.shared.frontmostApplication != .current
    }

    /// Set when a system touch event is dropped in favour of raw frames.
    private var touchesWithoutRawSince: TimeInterval?

    /// True when the system's touch events have kept arriving for 0.4 s with
    /// no raw frame in between, i.e. the private reader went silent.
    private func rawStreamLooksDead(_ touches: [TouchSample]) -> Bool {
        guard !touches.isEmpty else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        // A marker left over from an earlier stroke says nothing about this one.
        if let since = touchesWithoutRawSince, now - since < 1.5,
           MultitouchReader.shared.lastFrameUptime < since {
            guard now - since > 0.4 else { return false }
            touchesWithoutRawSince = nil
            return true
        }
        touchesWithoutRawSince = now
        return false
    }

    private func handleRawFrame(_ fingers: [MTFingerSample]) {
        guard usesRawTouches else { return }
        // States 3–4 touch; 5–6 are a contact fading out, kept so a pen that
        // flickers for a frame does not split the stroke.
        let touches = fingers.filter { (3...6).contains($0.state) }.map {
            TouchSample(id: $0.id, pos: $0.pos, deviceSize: currentDeviceSize, resting: false)
        }
        if touches.isEmpty, currentTouches.isEmpty, restingTouches.isEmpty { return }
        holdPointerInBackground()
        handle(.touches(touches))
    }

    private func handlePalmFiltered(_ touches: [TouchSample]) {
        let active = touches.filter { !$0.resting }
        let resting = touches.filter(\.resting)
        let shapes = contactShapes(for: active)
        let sizes = shapes.mapValues(\.size)
        let now = ProcessInfo.processInfo.systemUptime
        if useContactSize, MultitouchReader.shared.isAvailable,
           handleTwoFingerGesture(active: active, resting: resting, shapes: shapes, now: now) {
            TouchRecorder.shared.recordTouches(touches, pen: nil, rejected: [], sizes: sizes)
            return
        }
        palmRejector.penMaxMajor = penMaxMajor
        palmRejector.allowFinger = allowFinger
        let out = palmRejector.process(
            active,
            shapes: useContactSize && MultitouchReader.shared.isAvailable ? shapes : nil,
            now: now
        )
        rejectedTouches = out.rejected
        penShape = out.pen.flatMap { shapes[$0.id] }
        updatePenAim(pen: out.pen, rejected: out.rejected, resting: resting, shapes: shapes)
        TouchRecorder.shared.recordTouches(
            touches, pen: out.pen?.id, rejected: out.rejected.map(\.id), sizes: sizes
        )

        if out.previousPenEnded {
            if out.discardPrevious { cancelActiveDraft() }
            // Close the old stroke first, or the new pen would continue it.
            if out.pen != nil { handleTouches(resting) }
        }
        handleTouches((out.pen.map { [$0] } ?? []) + resting)
    }

    /// Tracks the palm, and on each new pen-down with the palm resting
    /// learns where the tip sits relative to it.
    private func updatePenAim(
        pen: TouchSample?, rejected: [TouchSample], resting: [TouchSample],
        shapes: [Int: PalmRejector.ContactShape]
    ) {
        // Fingers turned away (finger writing off) are not part of the palm.
        let palms = resting + rejected.filter { touch in
            !(shapes[touch.id].map(PalmRejector.isFingerShaped) ?? false)
        }
        let anchor = PenAim.anchor(of: palms.map(\.pos), hand: palmHand)
        if let pen, pen.id != lastPenID, let anchor, palmAnchor != nil, interactionMode == .zen {
            penAim.learn(anchor: anchor, pen: pen.pos)
            penAim.save(hand: palmHand)
        }
        lastPenID = pen?.id
        if anchor != palmAnchor {
            palmAnchor = anchor
            if showPenAim { overlayView.needsDisplay = true }
        }
    }

    /// Two round, fingertip-shaped contacts with no pen writing = pan + zoom,
    /// even with palm rejection on. Returns true when it consumed the frame.
    private func handleTwoFingerGesture(
        active: [TouchSample],
        resting: [TouchSample],
        shapes: [Int: PalmRejector.ContactShape],
        now: TimeInterval
    ) -> Bool {
        let ids = Set(active.map(\.id))
        if !navigatingIDs.isEmpty {
            let palmJoined = active.contains { shapes[$0.id].map(PalmRejector.isClearlyPalm) ?? false }
            if ids == navigatingIDs, !palmJoined {
                navigationLostAt = nil
                rejectedTouches = []
                handleTouches(active + resting)
                return true
            }
            // One finger dropped out for a moment: hold the canvas still.
            if ids.count == 1, ids.isSubset(of: navigatingIDs) {
                let lost = navigationLostAt ?? now
                navigationLostAt = lost
                if now - lost < 0.08 {
                    rejectedTouches = []
                    return true
                }
            }
            // The dropped finger came back under a new identity: carry on,
            // re-anchoring so the canvas does not jump.
            if ids.count == 2, ids.intersection(navigatingIDs).count == 1, !palmJoined,
               let newcomer = active.first(where: { !navigatingIDs.contains($0.id) }),
               shapes[newcomer.id].map(PalmRejector.isFingerShaped) ?? false {
                navigatingIDs = ids
                navigationLostAt = nil
                twoFingerBaseline = nil
                rejectedTouches = []
                handleTouches(active + resting)
                return true
            }
            // Gesture over: whichever finger is still down must not start ink.
            palmRejector.lockOut(navigatingIDs.intersection(ids))
            navigatingIDs = []
            navigationLostAt = nil
            handleTouches(resting)
            return false
        }

        // Start: two fingertips, clear of the bottom edge where the heel of the
        // hand rests (recorded drags stay above y 0.17; palm heels sit ≤0.05).
        guard active.count == 2,
              active.allSatisfy({ $0.pos.y > 0.06 && (shapes[$0.id].map(PalmRejector.isFingerShaped) ?? false) }),
              palmRejector.canYieldToGesture(now: now) else { return false }
        cancelActiveDraft()
        palmRejector.yieldToGesture()
        navigatingIDs = ids
        rejectedTouches = []
        handleTouches(active + resting)
        return true
    }

    /// Nearest private-reader contact per touch, when close enough to be the
    /// same physical contact. Empty when the reader is off or silent.
    private func contactShapes(for touches: [TouchSample]) -> [Int: PalmRejector.ContactShape] {
        guard MultitouchReader.shared.isAvailable else { return [:] }
        let fingers = MultitouchReader.shared.fingers
        var shapes: [Int: PalmRejector.ContactShape] = [:]
        for touch in touches {
            guard let finger = fingers.min(by: {
                squaredDistance($0.pos, touch.pos) < squaredDistance($1.pos, touch.pos)
            }), squaredDistance(finger.pos, touch.pos) < 0.08 * 0.08 else { continue }
            shapes[touch.id] = PalmRejector.ContactShape(
                size: finger.size, majorAxis: finger.majorAxis, minorAxis: finger.minorAxis
            )
        }
        return shapes
    }

    private func rawContactSizes(for touches: [TouchSample]) -> [Int: Double] {
        contactShapes(for: touches).mapValues(\.size)
    }

    private func handleTouches(_ touches: [TouchSample]) {
        let previousCount = currentTouches.count
        currentTouches = touches.filter { !$0.resting }
        restingTouches = touches.filter(\.resting)

        // Device size still comes from the raw set: a resting-only frame
        // carries a perfectly good deviceSize. Persist it so the next launch
        // starts with the pad rect already correct.
        if let sample = touches.first,
           sample.deviceSize.width > 0,
           sample.deviceSize.height > 0,
           sample.deviceSize != currentDeviceSize {
            currentDeviceSize = sample.deviceSize
            DeviceSizeStore.remember(sample.deviceSize)
        }

        // Every count transition below is in terms of ACTIVE touches only.
        let activeCount = currentTouches.count

        if activeCount != 2 {
            endTwoFingerNavigation()
        }
        if previousCount == 3, activeCount != 3 {
            endThreeFingerDraw()
        }

        if interactionMode == .zen,
           previousCount == 0,
           activeCount > 0 {
            freezeCursorIfNeeded()
        }

        switch activeCount {
        case 0:
            noteCalibrationLift()
            pressureInking = false
            if interactionMode == .zen {
                finishActiveDraft()
            } else {
                cancelActiveDraft()
            }

            matchedFinger = nil
            currentCursorViewPoint = nil
            isMouseDown = false
            resetPressureState()
            drawingSuppressedUntilRelease = false
            restoreCursorAssociation(force: true)

        case 1:
            guard interactionMode == .zen else {
                cancelActiveDraft()
                matchedFinger = nil
                currentCursorViewPoint = nil
                restoreCursorAssociation(force: true)
                needsDisplay = true
                return
            }

            refreshMatchedFinger()
            updateCursorPoint()
            updateSingleTouchInteraction()

        case 2:
            resetMultiTouchState()
            if previousCount != 2 {
                twoFingerBaseline = nil
            }
            if interactionMode == .zen {
                updateTwoFingerNavigation()
            }

        case 3:
            matchedFinger = nil
            if previousCount != 3 {
                // A draft from a different gesture must not bleed into this one.
                cancelActiveDraft()
                penFingerID = nil
            }
            // Once a 3-finger gesture has ended (the pen finger lifted while a
            // replacement kept the count at 3), don't silently start a new one
            // until the count leaves 3.
            if interactionMode == .zen,
               textEditor == nil,
               previousCount != 3 || isThreeFingerDrawing {
                updateThreeFingerDraw()
            } else if textEditor != nil {
                cancelActiveDraft()
                currentCursorViewPoint = nil
            }

        default:
            resetMultiTouchState()
        }

        needsDisplay = true
    }

    private func resetMultiTouchState() {
        cancelActiveDraft()
        matchedFinger = nil
        currentCursorViewPoint = nil
    }

    private func handleClick(down: Bool, location: CGPoint) {
        guard interactionMode == .zen else {
            isMouseDown = false
            resetPressureState()
            if down { handleToolbarClick(at: location) }
            return
        }

        // In zen mode the system pointer is frozen, so hit-testing must use the
        // finger-driven app cursor whenever a touch is present.
        let hitPoint = currentTouches.isEmpty ? location : preferredCursorPoint

        if down {
            isMouseDown = true
            if handleToolbarClick(at: hitPoint) {
                needsDisplay = true
                return
            }
            updateSingleTouchInteraction()
            needsDisplay = true
            return
        }

        isMouseDown = false
        resetPressureState()
        updateSingleTouchInteraction()
        needsDisplay = true
    }

    private enum ToolbarHit {
        case tool(BoardTool)
        case text
        case color(Int)
        case width(Int)
    }

    /// Left toolbar hit: a tool, the one-shot text button, a color or a width.
    /// Picking something from POINTER mode goes straight back to writing.
    @discardableResult
    private func handleToolbarClick(at point: CGPoint) -> Bool {
        guard let hit = toolbarHit(at: point) else { return false }
        if interactionMode == .pointer { enterZenMode() }
        switch hit {
        case .text:
            beginTextEditing(atViewPoint: preferredCursorPoint)
        case let .tool(tool):
            selectTool(tool)
        case let .color(index):
            selectColor(index)
        case let .width(index):
            activeWidthIndex = index
            needsDisplay = true
        }
        return true
    }

    private func handleKey(
        chars: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) {
        // While the text field owns the keyboard, every key is literal input —
        // Esc/Enter reach us through the NSControl command selectors instead.
        guard textEditor == nil else { return }

        let significantModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        // ⌘-shortcuts are menu items (responder-chain actions below).
        guard !significantModifiers.contains(.command) else { return }
        let lowercased = chars.lowercased()

        if keyCode == 53 || chars == "\u{1b}" {
            handleEscape()
            return
        }

        if keyCode == 51 || keyCode == 117 {
            deleteSelection()
            return
        }

        if lowercased == "[" || lowercased == "]" {
            guard let gate = pressureGate else {
                flash("先在「工具」菜单校准按压力度，才能调整")
                return
            }
            pressureGate = gate.scaled(by: lowercased == "[" ? 0.9 : 1.1)
            PressureGate.save(pressureGate)
            flash(lowercased == "[" ? "书写所需力度：更轻" : "书写所需力度：更重")
            return
        }

        if lowercased == "-" || lowercased == "=" {
            let delta = lowercased == "-" ? -0.25 : 0.25
            penMaxMajor = min(12, max(5, penMaxMajor + delta))
            flash(String(format: "笔尖长轴上限 %.2f mm", penMaxMajor))
            return
        }

        if lowercased == "c" {
            let step = significantModifiers.contains(.shift) ? -1 : 1
            selectColor((activeColorIndex + step + Self.palette.count) % Self.palette.count)
            return
        }

        if lowercased == "w" {
            let count = currentTool == .highlighter ? Self.highlighterWidths.count : Self.penWidths.count
            activeWidthIndex = (activeWidthIndex + 1) % count
            needsDisplay = true
            return
        }

        if lowercased == "t" {
            guard interactionMode == .zen else { return }
            // One-shot action: the active drawing tool is untouched.
            beginTextEditing(atViewPoint: preferredCursorPoint)
            return
        }

        if chars.count == 1,
           let value = Int(chars),
           let tool = BoardTool(rawValue: value) {
            selectTool(tool)
        }
    }

    /// Esc peels off the text editor, then the selection, and otherwise
    /// toggles zen ⇄ pointer.
    private func handleEscape() {
        if textEditor != nil {
            cancelTextEditing()
            return
        }
        if !currentSelection.isEmpty {
            clearSelection()
            return
        }

        if interactionMode == .zen {
            enterPointerMode()
        } else {
            enterZenMode()
        }
    }

    func toggleWritingMode() {
        handleEscape()
    }

    func enterWritingMode() {
        enterZenMode()
    }

    /// Before a modal panel: the pointer has to move.
    func enterPointerModeForDialog() {
        enterPointerMode()
    }

    private func selectColor(_ index: Int) {
        activeColorIndex = index
        let selected = currentSelection
        if !selected.isEmpty {
            model.recolor(selected, to: Self.palette[index].color)
            selectionRevision = model.revision
        }
        needsDisplay = true
    }

    private func flash(_ message: String) {
        flashText = message
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard self?.flashText == message else { return }
            self?.flashText = nil
            self?.needsDisplay = true
        }
    }

    // MARK: - Edit menu (responder chain: the text field handles these
    // itself while it is editing)

    @objc func undo(_ sender: Any?) {
        cancelActiveDraft()
        clearSelection()
        if model.undo() { needsDisplay = true }
    }

    @objc func redo(_ sender: Any?) {
        cancelActiveDraft()
        clearSelection()
        if model.redo() { needsDisplay = true }
    }

    @objc func copy(_ sender: Any?) {
        let selected = currentSelection
        guard !selected.isEmpty else { return }
        writeToPasteboard(selected.map { model.elements[$0] })
        flash("已复制 \(selected.count) 项")
    }

    @objc func cut(_ sender: Any?) {
        let selected = currentSelection
        guard !selected.isEmpty else { return }
        writeToPasteboard(selected.map { model.elements[$0] })
        deleteSelection()
    }

    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: Self.elementsType),
           let archived = try? JSONDecoder().decode([BoardArchive.Element].self, from: data) {
            let elements = archived.compactMap { try? $0.native() }
            place(elements, centeredAt: visibleCenter)
            return
        }
        if let image = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first {
            insertImage(image, centeredAt: visibleCenter)
        }
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection()
    }

    @objc override func selectAll(_ sender: Any?) {
        guard !model.isEmpty else { return }
        cancelActiveDraft()
        selectTool(.lasso)
        selection = IndexSet(model.elements.indices)
        selectionRevision = model.revision
        needsDisplay = true
    }

    @objc func duplicate(_ sender: Any?) {
        let selected = currentSelection
        guard !selected.isEmpty else { return }
        let offset = CGPoint(x: 24 / model.zoom, y: -24 / model.zoom)
        let copies = selected.map { model.elements[$0].translated(by: offset) }
        selection = model.append(contentsOf: copies)
        selectionRevision = model.revision
        needsDisplay = true
    }

    func clearBoard() {
        cancelActiveDraft()
        clearSelection()
        model.clear()
        needsDisplay = true
    }

    func resetView() {
        model.resetView()
        positionTextEditor()
        needsDisplay = true
    }

    func zoom(by factor: CGFloat) {
        model.zoom(by: factor, in: bounds)
        positionTextEditor()
        needsDisplay = true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return model.canUndo
        case #selector(redo(_:)): return model.canRedo
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)):
            return !currentSelection.isEmpty
        case #selector(selectAll(_:)): return !model.isEmpty
        case #selector(paste(_:)):
            let pasteboard = NSPasteboard.general
            return pasteboard.data(forType: Self.elementsType) != nil
                || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        default: return true
        }
    }

    // MARK: - Clipboard, images, drag and drop

    /// Private pasteboard type: the archived elements, so a paste is still
    /// editable ink. A PNG goes along for other apps (Pages, Notes, WeChat…).
    private static let elementsType = NSPasteboard.PasteboardType("local.macwriting.elements")

    private func writeToPasteboard(_ elements: [BoardElement]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(elements.map { try BoardArchive.Element($0) }) {
            item.setData(data, forType: Self.elementsType)
        }
        if let png = Self.png(of: elements, paper: paperColor) {
            item.setData(png, forType: .png)
        }
        pasteboard.writeObjects([item])
    }

    /// The elements alone on white, 2× scale, small margin.
    private static func png(of elements: [BoardElement], paper: NSColor) -> Data? {
        let box = elements.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !box.isNull else { return nil }
        let content = box.insetBy(dx: -12, dy: -12)
        let scale: CGFloat = 2
        let w = Int(content.width * scale), h = Int(content.height * scale)
        guard w * h < 200_000_000, let context = bitmapContext(width: w, height: h) else { return nil }
        let renderer = InkRenderer.fitting(content, into: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        renderer.drawPaper(.blank, in: CGRect(x: 0, y: 0, width: w, height: h), color: paper)
        elements.forEach { renderer.draw($0) }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Canvas point at the middle of the visible writing area.
    private var visibleCenter: CGPoint {
        model.viewToCanvas(CGPoint(x: contentRect.midX, y: contentRect.midY), in: bounds)
    }

    /// Inserts elements (one undo step) centered on `center` and selects
    /// them with the lasso, ready to be dragged into place.
    private func place(_ elements: [BoardElement], centeredAt center: CGPoint) {
        let box = elements.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !box.isNull else { return }
        cancelActiveDraft()
        let shift = CGPoint(x: center.x - box.midX, y: center.y - box.midY)
        let added = model.append(contentsOf: elements.map { $0.translated(by: shift) })
        if currentTool != .lasso { selectTool(.lasso) }
        selection = added
        selectionRevision = model.revision
        needsDisplay = true
    }

    /// Images arrive at up to 60% of the visible area, downsampled so a
    /// phone photo doesn't bloat the note.
    private func insertImage(_ image: NSImage, centeredAt center: CGPoint) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let image = Self.downsampled(image, maxPixels: 2400)
        let fit = min(1, contentRect.width * 0.6 / image.size.width, contentRect.height * 0.6 / image.size.height)
        let size = CGSize(width: image.size.width * fit / model.zoom, height: image.size.height * fit / model.zoom)
        place([.image(rect: CGRect(origin: .zero, size: size), image: image)], centeredAt: center)
    }

    private static func downsampled(_ image: NSImage, maxPixels: CGFloat) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let longest = CGFloat(max(cg.width, cg.height))
        let factor = min(1, maxPixels / longest)
        let w = Int(CGFloat(cg.width) * factor), h = Int(CGFloat(cg.height) * factor)
        guard let context = bitmapContext(width: w, height: h) else { return image }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return image }
        let rep = NSBitmapImageRep(cgImage: scaled)
        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSImage.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        var images = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
        if images.isEmpty, let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            images = urls.compactMap(NSImage.init(contentsOf:))
        }
        guard let image = images.first else { return false }
        let drop = convert(sender.draggingLocation, from: nil)
        insertImage(image, centeredAt: model.viewToCanvas(drop, in: bounds))
        window?.makeKey()
        return true
    }

    // MARK: - Touch-to-canvas drawing

    private func pollMultitouch() {
        if TouchRecorder.shared.isRecording { needsDisplay = true }
        // Touch events stop once the pointer leaves the panel, so this
        // cannot rely on them alone.
        holdPointerInBackground()
        guard interactionMode == .zen,
              currentTouches.count == 1 else {
            matchedFinger = nil
            return
        }

        refreshMatchedFinger()
        updateCursorPoint()
        updateSingleTouchInteraction()
        needsDisplay = true
    }

    private func refreshMatchedFinger() {
        guard MultitouchReader.shared.isAvailable,
              let touch = currentTouches.first else {
            matchedFinger = nil
            return
        }

        matchedFinger = MultitouchReader.shared.fingers.min { lhs, rhs in
            squaredDistance(lhs.pos, touch.pos) < squaredDistance(rhs.pos, touch.pos)
        }
        let pressure = matchedFinger?.pressure ?? 0
        if pressCalibration != nil {
            recordCalibrationSample(pressure)
        } else if let gate = pressureGate, !drawOnContact {
            pressureInking = gate.isInking(pressure: pressure, wasInking: pressureInking)
        }
    }

    // MARK: Pressure calibration

    /// Two stretches of samples: light touching, then (after a lift) writing
    /// pressure. Nothing inks meanwhile; the status strip leads the way.
    func startPressureCalibration() {
        guard MultitouchReader.shared.isAvailable else {
            flash("需要先在“输入监控”中授权，才能读取按压力度")
            return
        }
        cancelActiveDraft()
        enterZenMode()
        pressCalibration = .light([])
        needsDisplay = true
    }

    private func recordCalibrationSample(_ pressure: Double) {
        switch pressCalibration {
        case .light(var samples):
            samples.append(pressure)
            pressCalibration = samples.count >= Self.calibrationSamples ? .waitingForLift(light: samples) : .light(samples)
        case let .firm(light, firm):
            let firm = firm + [pressure]
            if firm.count >= Self.calibrationSamples {
                finishPressureCalibration(light: light, firm: firm)
            } else {
                pressCalibration = .firm(light: light, firm)
            }
        case .waitingForLift, nil:
            break
        }
        needsDisplay = true
    }

    private func noteCalibrationLift() {
        if case let .waitingForLift(light) = pressCalibration {
            pressCalibration = .firm(light: light, [])
            needsDisplay = true
        }
    }

    private func finishPressureCalibration(light: [Double], firm: [Double]) {
        pressCalibration = nil
        drawingSuppressedUntilRelease = true   // the calibration press must not ink
        switch PressureGate.calibrate(light: light, firm: firm) {
        case let .success(gate):
            pressureGate = gate
            PressureGate.save(gate)
            drawOnContact = false
            flash("校准完成：轻触显示位置，稍用力即可书写（[ / ] 微调）")
        case .failure(.noPressureData):
            flash("这台触控板没有提供压力数据：轻触显示位置，按下（点按）才书写")
        case .failure(.notSeparable):
            flash("轻重两种力度区分不开，请再校准一次，按的时候更用力一些")
        }
    }

    private var calibrationPrompt: String? {
        switch pressCalibration {
        case let .light(samples):
            return "校准 1/2：笔尖轻轻接触触控板并慢慢移动（\(samples.count * 100 / Self.calibrationSamples)%）"
        case .waitingForLift:
            return "校准 2/2：先抬起笔"
        case let .firm(_, samples):
            return "校准 2/2：用平时写字的力度按着移动（\(samples.count * 100 / Self.calibrationSamples)%）"
        case nil:
            return nil
        }
    }

    private func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private func updateCursorPoint() {
        guard let touch = currentTouches.first else {
            currentCursorViewPoint = nil
            return
        }

        let point = TrackpadGeometry.map(touch.pos, into: trackpadRect)
        currentCursorViewPoint = point
        lastCursorViewPoint = point
    }

    /// Laser pointer: while ⌥ is held the pen only shows where it is. Read
    /// from the session state, so it works over other apps too.
    private var isLaserHeld: Bool {
        interactionMode == .zen
            && CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }

    private var isDrawingRequested: Bool {
        interactionMode == .zen && pressCalibration == nil &&
            (drawOnContact || isMouseDown || pressureInking)
    }

    private var currentForceNorm: CGFloat {
        if isMouseDown {
            return currentPressure
        }
        return min(1, CGFloat((matchedFinger?.size ?? 0) / 1.5))
    }

    private func updateSingleTouchInteraction() {
        guard interactionMode == .zen,
              currentTouches.count == 1,
              let cursorPoint = currentCursorViewPoint else { return }

        guard textEditor == nil else {
            cancelActiveDraft()
            return
        }

        if isLaserHeld {
            finishActiveDraft()
            // Letting go of the key mid-touch must not start a stroke there.
            drawingSuppressedUntilRelease = true
            needsDisplay = true
            return
        }

        guard isDrawingRequested else {
            finishActiveDraft()
            drawingSuppressedUntilRelease = false
            return
        }

        guard !drawingSuppressedUntilRelease else { return }

        continueGesture(at: model.viewToCanvas(cursorPoint, in: bounds))
        needsDisplay = true
    }

    /// One frame of the active tool under the pen (single touch or the
    /// three-finger force draw): erase, lasso / drag the selection, or ink.
    private func continueGesture(at canvasPoint: CGPoint) {
        if currentTool == .eraser {
            let from = eraserLastPoint ?? canvasPoint
            if model.erase(
                from: from,
                to: canvasPoint,
                radius: eraserRadius / model.zoom,
                partial: !eraseWholeStrokes,
                recordingUndo: !eraserGestureErased
            ) {
                eraserGestureErased = true
            }
            eraserLastPoint = canvasPoint
            return
        }

        let width = inkWidth(for: currentTool)
        guard var draft = activeDraft else {
            var draft = Draft(
                tool: currentTool,
                start: canvasPoint,
                current: canvasPoint,
                strokeSamples: [BoardStrokeSample(point: canvasPoint, width: width)],
                width: width,
                color: inkColor(for: currentTool)
            )
            if currentTool == .lasso {
                // Pen down on the selection drags it; anywhere else starts a
                // new lasso.
                let reach = 10 / model.zoom
                if !currentSelection.isEmpty,
                   model.bounds(of: currentSelection).insetBy(dx: -reach, dy: -reach).contains(canvasPoint) {
                    draft.movesSelection = true
                } else {
                    clearSelection()
                }
            }
            activeDraft = draft
            return
        }
        guard draft.tool == currentTool else {
            cancelActiveDraft()
            return
        }

        draft.current = canvasPoint
        if draft.movesSelection {
            selectionOffset = CGPoint(x: canvasPoint.x - draft.start.x, y: canvasPoint.y - draft.start.y)
        } else if draft.tool.isFreehand || draft.tool == .lasso {
            let minimumStep = (draft.tool == .lasso ? 3 : 0.6) / model.zoom
            if let last = draft.strokeSamples.last,
               hypot(last.point.x - canvasPoint.x, last.point.y - canvasPoint.y) >= minimumStep {
                // Light EMA on position: the raw stream is noisy at sub-point
                // spacing and shows up as visible chatter.
                let smoothedPoint = CGPoint(
                    x: last.point.x * 0.35 + canvasPoint.x * 0.65,
                    y: last.point.y * 0.35 + canvasPoint.y * 0.65
                )
                draft.strokeSamples.append(BoardStrokeSample(point: smoothedPoint, width: width))
            }
        }
        activeDraft = draft
    }

    private func endEraserGesture() {
        eraserLastPoint = nil
        eraserGestureErased = false
    }

    private func finishActiveDraft() {
        endEraserGesture()
        guard let draft = activeDraft else { return }
        activeDraft = nil

        switch draft.tool {
        case .pen, .highlighter:
            model.append(.stroke(samples: draft.strokeSamples, color: draft.color))
        case .line:
            model.append(.line(start: draft.start, end: draft.current, width: draft.width, color: draft.color))
        case .rectangle:
            model.append(.rectangle(rect: rect(from: draft.start, to: draft.current), width: draft.width, color: draft.color))
        case .ellipse:
            model.append(.ellipse(rect: rect(from: draft.start, to: draft.current), width: draft.width, color: draft.color))
        case .arrow:
            model.append(.arrow(start: draft.start, end: draft.current, width: draft.width, color: draft.color))
        case .lasso:
            if draft.movesSelection {
                let selected = currentSelection
                let offset = selectionOffset
                selectionOffset = .zero
                model.translate(selected, by: offset)
                selection = selected
                selectionRevision = model.revision
            } else {
                selection = model.indices(inLasso: draft.strokeSamples.map(\.point))
                selectionRevision = model.revision
            }
        case .eraser:
            break
        }
        needsDisplay = true
    }

    private func cancelActiveDraft() {
        endEraserGesture()
        activeDraft = nil
        selectionOffset = .zero
        needsDisplay = true
    }

    private func clearSelection() {
        selection = []
        selectionOffset = .zero
        needsDisplay = true
    }

    private func deleteSelection() {
        let selected = currentSelection
        guard !selected.isEmpty else { return }
        cancelActiveDraft()
        clearSelection()
        model.remove(selected)
        needsDisplay = true
    }

    private func selectTool(_ tool: BoardTool) {
        cancelActiveDraft()
        if tool != .lasso { clearSelection() }
        currentTool = tool
        if isDrawingRequested {
            drawingSuppressedUntilRelease = true
        }
        needsDisplay = true
    }

    func selectToolFromMenu(_ tool: BoardTool) {
        selectTool(tool)
    }

    // MARK: - Two-finger navigation (raw touches)

    /// Derives pan and zoom from the same pair of raw touches every frame, so
    /// both apply simultaneously — unlike the system gestures, where a
    /// recognized pinch stops the scroll stream. There is deliberately NO
    /// dominant-axis test, no gesture classification and no threshold that
    /// latches one component: every frame applies whatever translation and
    /// whatever scale the fingers actually show.
    private func updateTwoFingerNavigation() {
        guard currentTouches.count == 2 else {
            endTwoFingerNavigation()
            return
        }

        // Normalized pad space — see TwoFingerBaseline.
        let p0 = currentTouches[0].pos
        let p1 = currentTouches[1].pos
        let centroid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let spread = hypot(p1.x - p0.x, p1.y - p0.y)

        defer {
            twoFingerBaseline = TwoFingerBaseline(centroid: centroid, spread: spread)
            isTwoFingerNavigating = true
        }

        // No baseline yet (1→2, 3→2, gesture start): adopt it without moving.
        guard let baseline = twoFingerBaseline else { return }

        let rect = trackpadRect
        // Both baseline and current are mapped through the SAME current rect,
        // so a rect change between frames can't inject a phantom pan.
        let previousCentroid = TrackpadGeometry.map(baseline.centroid, into: rect)
        let currentCentroid = TrackpadGeometry.map(centroid, into: rect)

        let factor: CGFloat = (baseline.spread > 0.01 && spread > 0.01)
            ? min(2, max(0.5, spread / baseline.spread))
            : 1
        let anchor = model.viewToCanvas(previousCentroid, in: bounds)
        model.navigate(scale: factor, anchor: anchor, to: currentCentroid, in: bounds)
        positionTextEditor()
    }

    private func endTwoFingerNavigation() {
        twoFingerBaseline = nil
        isTwoFingerNavigating = false
    }

    // MARK: - Three-finger force draw

    /// Three fingers draw with the active tool at full force, no click and no
    /// per-finger size threshold. The pen is the LEFTMOST finger at gesture
    /// start and stays locked to that identity until release — a finger drifting
    /// further left mid-stroke must not steal the pen.
    private func updateThreeFingerDraw() {
        guard currentTouches.count == 3 else { return }

        if penFingerID == nil {
            penFingerID = currentTouches.min(by: { $0.pos.x < $1.pos.x })?.id
        }
        guard let penID = penFingerID,
              let pen = currentTouches.first(where: { $0.id == penID }) else {
            // The pen finger lifted (replaced by another) — that ends the
            // gesture and commits, exactly like dropping below three.
            endThreeFingerDraw()
            return
        }

        let penPoint = TrackpadGeometry.map(pen.pos, into: trackpadRect)
        currentCursorViewPoint = penPoint
        lastCursorViewPoint = penPoint
        isThreeFingerDrawing = true
        continueGesture(at: model.viewToCanvas(penPoint, in: bounds))
    }

    /// Dropping below three fingers commits the element rather than discarding it.
    private func endThreeFingerDraw() {
        penFingerID = nil
        guard isThreeFingerDrawing else { return }
        isThreeFingerDrawing = false
        currentCursorViewPoint = nil
        guard interactionMode == .zen else {
            cancelActiveDraft()
            return
        }
        finishActiveDraft()
        // Fingers lift one at a time; don't let the survivor restart a stroke.
        drawingSuppressedUntilRelease = true
    }

    // MARK: - Text

    private func beginTextEditing(atViewPoint viewPoint: CGPoint) {
        if textEditor != nil {
            commitTextEditing()
        }

        let editor = NSTextField()
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = true
        editor.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 0.96)
        editor.textColor = inkColor
        editor.focusRingType = .none
        editor.placeholderString = "输入文字，回车完成"
        editor.delegate = self
        editor.cell?.isScrollable = true
        editor.cell?.wraps = false
        editor.cell?.lineBreakMode = .byClipping

        textEditor = editor
        textEditorCanvasOrigin = model.viewToCanvas(viewPoint, in: bounds)
        drawingSuppressedUntilRelease = true
        addSubview(editor)
        positionTextEditor()
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    /// The editor lives in view space, so it always renders at the base point
    /// size; only its anchor follows the canvas.
    private func positionTextEditor() {
        guard let editor = textEditor,
              let origin = textEditorCanvasOrigin else { return }

        let viewPoint = model.canvasToView(origin, in: bounds)
        let font = NSFont.systemFont(ofSize: textBaseFontSize, weight: .medium)
        editor.font = font

        let editorHeight = max(26, ceil(font.ascender - font.descender + 10))
        let editorWidth = min(360, max(160, bounds.width * 0.32))
        let minimumX = contentRect.minX
        let x = min(
            max(minimumX, viewPoint.x - textEditorTextInset.width),
            max(minimumX, bounds.maxX - editorWidth - edgeInset)
        )
        let minimumY = statusHeight + 8
        let y = min(
            max(minimumY, viewPoint.y - textEditorTextInset.height),
            max(minimumY, bounds.maxY - editorHeight - 8)
        )
        editor.frame = CGRect(
            x: x,
            y: y,
            width: editorWidth,
            height: editorHeight
        )
    }

    private func commitTextEditing() {
        guard !isEndingTextEdit, let editor = textEditor else { return }

        isEndingTextEdit = true
        let string = editor.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let editorFrame = editor.frame
        textEditor = nil
        textEditorCanvasOrigin = nil
        editor.delegate = nil
        editor.removeFromSuperview()

        if !string.isEmpty {
            // Commit where the glyphs actually sat (the editor may have been
            // clamped into the view), at the size they were shown.
            let glyphOrigin = CGPoint(
                x: editorFrame.minX + textEditorTextInset.width,
                y: editorFrame.minY + textEditorTextInset.height
            )
            model.append(
                .text(
                    origin: model.viewToCanvas(glyphOrigin, in: bounds),
                    string: string,
                    fontSize: textBaseFontSize / model.zoom,
                    color: inkColor
                )
            )
        }
        window?.makeFirstResponder(captureView)
        isEndingTextEdit = false
        needsDisplay = true
    }

    private func cancelTextEditing() {
        guard !isEndingTextEdit, let editor = textEditor else { return }

        isEndingTextEdit = true
        textEditor = nil
        textEditorCanvasOrigin = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(captureView)
        isEndingTextEdit = false
        needsDisplay = true
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            handleEscape()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === textEditor else { return }
        commitTextEditing()
    }

    // MARK: - Zen / pointer mode and cursor safety

    private func freezeCursorIfNeeded() {
        guard interactionMode == .zen,
              window?.isKeyWindow == true,
              !cursorFrozen else { return }

        _ = CGAssociateMouseAndMouseCursorPosition(0)
        cursorFrozen = true
    }

    private func restoreCursorAssociation(force: Bool) {
        guard force || cursorFrozen else { return }
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        cursorFrozen = false
        BackgroundCursor.show()
    }

    /// Writing in the mini window over another app. Its key panel makes
    /// AppKit report the app active, but the window server still has the
    /// other app in front, so the frozen pointer does not apply (the
    /// pointer wandered out of the panel, and the touches followed it).
    private func holdPointerInBackground() {
        guard interactionMode == .zen,
              NSWorkspace.shared.frontmostApplication != .current,
              let window, window.isKeyWindow else { return }
        BackgroundCursor.hide()
        BackgroundCursor.pin(to: window)
        cursorFrozen = true   // so leaving zen mode shows the pointer again
    }

    private func enterZenMode() {
        interactionMode = .zen
        if !currentTouches.isEmpty {
            drawingSuppressedUntilRelease = true
            freezeCursorIfNeeded()
        }
        window?.makeFirstResponder(captureView)
        applySystemCursorForCurrentMode()
        holdPointerInBackground()
        needsDisplay = true
    }

    private func enterPointerMode() {
        interactionMode = .pointer
        cancelActiveDraft()
        cancelTextEditing()
        endTwoFingerNavigation()
        isThreeFingerDrawing = false
        penFingerID = nil
        currentTouches.removeAll(keepingCapacity: true)
        restingTouches.removeAll(keepingCapacity: true)
        rejectedTouches.removeAll(keepingCapacity: true)
        palmAnchor = nil
        lastPenID = nil
        navigatingIDs.removeAll()
        palmRejector.reset()
        matchedFinger = nil
        currentCursorViewPoint = nil
        isMouseDown = false
        resetPressureState()
        drawingSuppressedUntilRelease = false
        restoreCursorAssociation(force: true)
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func applySystemCursorForCurrentMode() {
        window?.invalidateCursorRects(for: self)
        guard interactionMode == .zen,
              let window,
              window.isKeyWindow else {
            NSCursor.arrow.set()
            return
        }

        let mousePoint = convert(
            window.mouseLocationOutsideOfEventStream,
            from: nil
        )
        if bounds.contains(mousePoint) {
            transparentCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private static func makeTransparentCursor() -> NSCursor {
        let image = NSImage(size: CGSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }

    private func resetPressureState() {
        currentPressure = 0
    }

    private func updateWindowObservation() {
        guard observedWindow !== window else { return }

        restoreCursorAssociation(force: true)
        NSCursor.arrow.set()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()

        observedWindow = window
        guard let window else { return }

        // Losing key must always release the cursor (hard safety rule) — but
        // dropping to pointer mode silently is how a user ends up testing
        // gestures in the mode where the OS makes them exclusive. Remember that
        // we were in zen and restore it when the window comes back.
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.resumeZenOnKey = self.interactionMode == .zen
                self.enterPointerMode()
            }
        )
        windowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.resumeZenOnKey else { return }
                self.resumeZenOnKey = false
                self.enterZenMode()
            }
        )
    }

    // MARK: - Layout

    /// Drawing area left over once the docked toolbar and status strip are out.
    private var contentRect: CGRect {
        let left = edgeInset * 2 + toolbarWidth
        return CGRect(
            x: left,
            y: statusHeight,
            width: max(1, bounds.width - left - edgeInset),
            height: max(1, bounds.height - statusHeight - edgeInset)
        )
    }

    private var trackpadRect: CGRect {
        TrackpadGeometry.padRect(
            in: contentRect,
            deviceSize: currentDeviceSize,
            // Nearly the whole drawing area: the trackpad is small, so every
            // point of canvas it can reach makes the writing roomier.
            fraction: 0.94
        )
    }

    private var swatchRows: Int { (Self.palette.count + 1) / 2 }

    /// Tools, the one-shot text button, colors, widths — top to bottom.
    private var toolbarRect: CGRect {
        let height = 6 + toolbarItemHeight * CGFloat(BoardTool.allCases.count)
            + sectionGap + toolbarItemHeight
            + sectionGap + swatchRowHeight * CGFloat(swatchRows)
            + 4 + widthRowHeight + 6
        let y = min(
            max(statusHeight + edgeInset, bounds.midY - height / 2),
            max(statusHeight + edgeInset, bounds.maxY - height - edgeInset)
        )
        return CGRect(x: edgeInset, y: y, width: toolbarWidth, height: height)
    }

    private func toolbarItemRects() -> [(BoardTool, CGRect)] {
        let rect = toolbarRect
        return BoardTool.allCases.map { tool in
            let index = CGFloat(tool.rawValue - 1)
            return (tool, CGRect(
                x: rect.minX + 6,
                y: rect.maxY - 6 - (index + 1) * toolbarItemHeight,
                width: rect.width - 12,
                height: toolbarItemHeight
            ))
        }
    }

    /// Below the tools and visually detached — text is an action, never a mode,
    /// so this button never renders as "selected".
    private var textButtonRect: CGRect {
        let rect = toolbarRect
        let toolsHeight = toolbarItemHeight * CGFloat(BoardTool.allCases.count)
        return CGRect(
            x: rect.minX + 6,
            y: rect.maxY - 6 - toolsHeight - sectionGap - toolbarItemHeight,
            width: rect.width - 12,
            height: toolbarItemHeight
        )
    }

    private func swatchRects() -> [CGRect] {
        let top = textButtonRect.minY - sectionGap
        let cellWidth = (toolbarWidth - 12) / 2
        return Self.palette.indices.map { i in
            CGRect(
                x: toolbarRect.minX + 6 + CGFloat(i % 2) * cellWidth,
                y: top - CGFloat(i / 2 + 1) * swatchRowHeight,
                width: cellWidth,
                height: swatchRowHeight
            )
        }
    }

    private func widthRects() -> [CGRect] {
        let count = Self.penWidths.count
        let cellWidth = (toolbarWidth - 12) / CGFloat(count)
        let y = toolbarRect.minY + 6
        return (0..<count).map { i in
            CGRect(x: toolbarRect.minX + 6 + CGFloat(i) * cellWidth, y: y, width: cellWidth, height: widthRowHeight)
        }
    }

    private func toolbarHit(at point: CGPoint) -> ToolbarHit? {
        guard toolbarRect.contains(point) else { return nil }
        if let tool = toolbarItemRects().first(where: { $0.1.contains(point) })?.0 { return .tool(tool) }
        if textButtonRect.contains(point) { return .text }
        if let i = swatchRects().firstIndex(where: { $0.contains(point) }) { return .color(i) }
        if let i = widthRects().firstIndex(where: { $0.contains(point) }) { return .width(i) }
        return nil
    }

    private var preferredCursorPoint: CGPoint {
        currentCursorViewPoint ??
            lastCursorViewPoint ??
            CGPoint(x: contentRect.midX, y: contentRect.midY)
    }

    // MARK: - Rendering

    private func displayColor(_ color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.genericRGB),
              let legacy = Self.legacyInk.usingColorSpace(.genericRGB) else { return color }
        let isLegacy = abs(c.redComponent - legacy.redComponent) < 0.02
            && abs(c.greenComponent - legacy.greenComponent) < 0.02
            && abs(c.blueComponent - legacy.blueComponent) < 0.02
        let isWhite = c.redComponent > 0.97 && c.greenComponent > 0.97 && c.blueComponent > 0.97
        return isLegacy || isWhite ? Self.palette[0].color.withAlphaComponent(c.alphaComponent) : color
    }

    private func displayed(_ element: BoardElement) -> BoardElement {
        element.recolored(displayColor)
    }

    /// The lassoed elements (left out of the cache), following a live drag,
    /// inside a dashed frame.
    private func drawSelection() {
        let selected = currentSelection
        guard !selected.isEmpty else { return }
        let renderer = model.renderer(in: bounds)
        let offset = selectionOffset
        if offset != .zero, let image = selectionImage(selected),
           let context = NSGraphicsContext.current?.cgContext {
            // Dragging: the selection was rasterized once; each frame only
            // shifts the bitmap.
            context.draw(image, in: bounds.offsetBy(dx: offset.x * renderer.scale, dy: offset.y * renderer.scale))
        } else {
            for i in selected where model.elements.indices.contains(i) {
                renderer.draw(displayed(model.elements[i]))
            }
        }
        let box = renderer.rect(model.bounds(of: selected).offsetBy(dx: offset.x, dy: offset.y))
            .insetBy(dx: -6, dy: -6)
        let frame = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        accentColor.withAlphaComponent(0.05).setFill()
        frame.fill()
        frame.setLineDash([5, 4], count: 2, phase: 0)
        frame.lineWidth = 1.2
        accentColor.withAlphaComponent(0.8).setStroke()
        frame.stroke()
    }

    private struct SelectionImageKey: Equatable {
        let selection: IndexSet
        let revision: Int
        let zoom: CGFloat
        let pan: CGPoint
        let size: CGSize
    }
    private var selectionImageCache: (key: SelectionImageKey, image: CGImage)?

    private func selectionImage(_ selected: IndexSet) -> CGImage? {
        let key = SelectionImageKey(selection: selected, revision: model.revision,
                                    zoom: model.zoom, pan: model.pan, size: bounds.size)
        if let cached = selectionImageCache, cached.key == key { return cached.image }
        let scale = window?.backingScaleFactor ?? 2
        guard let context = Self.bitmapContext(width: Int(bounds.width * scale), height: Int(bounds.height * scale))
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let renderer = model.renderer(in: bounds)
        for i in selected where model.elements.indices.contains(i) {
            renderer.draw(displayed(model.elements[i]))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        selectionImageCache = (key, image)
        return image
    }

    private func drawActiveDraft() {
        guard let draft = activeDraft else { return }
        let renderer = model.renderer(in: bounds)

        let element: BoardElement
        switch draft.tool {
        case .pen, .highlighter:
            renderer.draw(displayed(.stroke(samples: draft.strokeSamples, color: draft.color)))
            return
        case .lasso:
            guard !draft.movesSelection, draft.strokeSamples.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: renderer.point(draft.strokeSamples[0].point))
            for sample in draft.strokeSamples.dropFirst() { path.line(to: renderer.point(sample.point)) }
            path.close()
            accentColor.withAlphaComponent(0.06).setFill()
            path.fill()
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.lineWidth = 1.3
            accentColor.withAlphaComponent(0.85).setStroke()
            path.stroke()
            return
        case .line:
            element = .line(start: draft.start, end: draft.current, width: draft.width, color: draft.color)
        case .rectangle:
            element = .rectangle(rect: rect(from: draft.start, to: draft.current), width: draft.width, color: draft.color)
        case .ellipse:
            element = .ellipse(rect: rect(from: draft.start, to: draft.current), width: draft.width, color: draft.color)
        case .arrow:
            element = .arrow(start: draft.start, end: draft.current, width: draft.width, color: draft.color)
        case .eraser:
            return
        }
        renderer.draw(displayed(element), alpha: 0.72)
    }

    private func fillDot(at point: CGPoint, radius: CGFloat) {
        let diameter = max(0.7, radius * 2)
        NSBezierPath(ovalIn: CGRect(
            x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter
        )).fill()
    }

    /// Four corner brackets — a whisper of where the pad maps to, with no frame
    /// around the artwork.
    private func drawTrackpadOverlay() {
        let rect = trackpadRect
        let arm = min(22, min(rect.width, rect.height) * 0.09)
        guard arm > 2 else { return }

        let path = NSBezierPath()
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
            (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
            (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: corner.x + arm * CGFloat(dx), y: corner.y))
            path.line(to: corner)
            path.line(to: CGPoint(x: corner.x, y: corner.y + arm * CGFloat(dy)))
        }

        NSColor(calibratedWhite: 0, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawEmptyStateHint() {
        guard model.isEmpty, activeDraft == nil else { return }

        let text = "把笔放在触控板上开始书写 · 数字键 1–8 换工具 · C 换颜色 · Esc 切换书写 / 指针"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0, alpha: 0.38),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let pad = trackpadRect
        let y = max(statusHeight + 18, pad.minY - 34)
        (text as NSString).draw(
            at: CGPoint(x: pad.midX - size.width / 2, y: y),
            withAttributes: attributes
        )
    }

    /// Crosshair where the pen should land, inside a soft disc as wide as
    /// the prediction's typical error. Only while the palm rests and the pen
    /// is up.
    private func drawPenAim() {
        guard showPenAim, interactionMode == .zen, currentTouches.isEmpty, !isThreeFingerDrawing,
              textEditor == nil, let anchor = palmAnchor else { return }
        let point = TrackpadGeometry.map(penAim.predict(from: anchor), into: trackpadRect)
        let radius = min(36, max(10, penAim.spread * trackpadRect.width * 0.6))
        // Always the accent blue: it must read against ink of any color.
        let tint = accentColor

        let disc = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        tint.withAlphaComponent(0.06).setFill()
        disc.fill()
        disc.setLineDash([3, 4], count: 2, phase: 0)
        disc.lineWidth = 1
        tint.withAlphaComponent(0.45).setStroke()
        disc.stroke()

        let arm: CGFloat = 6
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: point.x - arm, y: point.y))
        cross.line(to: CGPoint(x: point.x + arm, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - arm))
        cross.line(to: CGPoint(x: point.x, y: point.y + arm))
        cross.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()   // halo over dark ink
        cross.lineWidth = 4
        cross.stroke()
        tint.setStroke()
        cross.lineWidth = 1.8
        cross.stroke()
    }

    private func drawTouchMarkers() {
        guard interactionMode == .zen else { return }

        // Ghosts: visible, but deliberately not part of any gesture.
        drawTouchRings(restingTouches, alpha: 0.11)
        drawTouchRings(rejectedTouches, alpha: 0.6, color: .systemRed)

        guard currentTouches.count >= 2 else { return }
        let points = drawTouchRings(currentTouches, alpha: 1)

        if points.count == 2 {
            let link = NSBezierPath()
            link.move(to: points[0])
            link.line(to: points[1])
            link.lineWidth = 1
            NSColor(calibratedWhite: 0, alpha: 0.16).setStroke()
            link.stroke()
        }
    }

    @discardableResult
    private func drawTouchRings(
        _ touches: [TouchSample],
        alpha: CGFloat,
        color: NSColor = .black
    ) -> [CGPoint] {
        guard !touches.isEmpty else { return [] }

        let points = touches.map { TrackpadGeometry.map($0.pos, into: trackpadRect) }
        for point in points {
            let ring = NSBezierPath(
                ovalIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            )
            color.withAlphaComponent(0.08 * alpha).setFill()
            ring.fill()
            color.withAlphaComponent(0.34 * alpha).setStroke()
            ring.lineWidth = 1
            ring.stroke()
        }
        return points
    }

    private func drawCursor() {
        guard let point = currentCursorViewPoint,
              currentTouches.count == 1 || isThreeFingerDrawing else { return }

        if isLaserHeld, !isThreeFingerDrawing {
            drawLaserDot(at: point)
            return
        }
        let drawing = isDrawingRequested || isThreeFingerDrawing
        if !drawing, !drawOnContact || pressCalibration != nil, currentTool != .eraser {
            drawAimCursor(at: point)
            return
        }
        let erasing = currentTool == .eraser
        // The eraser ring is drawn at its true reach; ink tools show their color.
        let radius: CGFloat = erasing ? eraserRadius : (drawing ? 8 : 6.5)
        let tint: NSColor
        switch currentTool {
        case .eraser: tint = .systemPink
        case .lasso: tint = accentColor
        default: tint = drawing ? Self.palette[activeColorIndex].color : NSColor(calibratedWhite: 0.25, alpha: 1)
        }
        let ring = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))

        NSGraphicsContext.saveGraphicsState()
        applySoftShadow(blur: 7, offsetY: -1, alpha: 0.55)
        tint.withAlphaComponent(drawing ? 0.14 : 0.09).setFill()
        ring.fill()
        NSGraphicsContext.restoreGraphicsState()

        tint.withAlphaComponent(drawing ? 0.6 : 0.4).setStroke()
        ring.lineWidth = drawing ? 1.6 : 1
        ring.stroke()

        tint.withAlphaComponent(drawing ? 1 : 0.85).setFill()
        fillDot(at: point, radius: (drawing ? 3.4 : 2.6) / 2)
    }

    /// Laser pointer: a red dot with a soft glow, bright enough to find at a glance.
    private func drawLaserDot(at point: CGPoint) {
        let red = NSColor(calibratedRed: 0.95, green: 0.16, blue: 0.12, alpha: 1)
        for (radius, alpha) in [(16.0, 0.10), (10.0, 0.18), (6.5, 0.35)] as [(CGFloat, CGFloat)] {
            red.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }
        red.setFill()
        fillDot(at: point, radius: 4)
        NSColor.white.withAlphaComponent(0.9).setFill()
        fillDot(at: point, radius: 1.5)
    }

    /// Light touch in press-to-write mode: a small blue ring and dot where
    /// the pen is. With calibrated pressure an arc fills toward the press
    /// threshold, so the hand learns how hard "write" is.
    private func drawAimCursor(at point: CGPoint) {
        let radius: CGFloat = 6
        let ring = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        NSColor.white.withAlphaComponent(0.85).setStroke()
        ring.lineWidth = 3.5
        ring.stroke()
        accentColor.withAlphaComponent(0.5).setStroke()
        ring.lineWidth = 1.2
        ring.stroke()
        if let gate = pressureGate, pressCalibration == nil, let pressure = matchedFinger?.pressure, gate.press > 0 {
            let fraction = min(1, max(0, pressure / gate.press))
            let arc = NSBezierPath()
            arc.appendArc(withCenter: point, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            accentColor.setStroke()
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            arc.stroke()
        }
        accentColor.setFill()
        fillDot(at: point, radius: 1.4)
    }

    private func drawToolbar() {
        let rect = toolbarRect
        let card = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)

        NSGraphicsContext.saveGraphicsState()
        applySoftShadow(blur: 16, offsetY: -4, alpha: 0.45)
        NSColor(calibratedWhite: 0.985, alpha: 0.97).setFill()
        card.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0, alpha: 0.12).setStroke()
        card.lineWidth = 1
        card.stroke()

        for (tool, itemRect) in toolbarItemRects() {
            let active = tool == currentTool
            if active {
                let highlight = NSBezierPath(roundedRect: itemRect.insetBy(dx: 0, dy: 2), xRadius: 9, yRadius: 9)
                accentColor.withAlphaComponent(0.2).setFill()
                highlight.fill()
                accentColor.withAlphaComponent(0.42).setStroke()
                highlight.lineWidth = 1
                highlight.stroke()
            }
            let tint = active ? accentColor : NSColor(calibratedWhite: 0.15, alpha: 0.7)
            drawGlyph(
                for: tool,
                in: CGRect(x: itemRect.minX, y: itemRect.minY + 12, width: itemRect.width, height: itemRect.height - 15),
                color: tint
            )
            drawCenteredLabel(
                "\(tool.rawValue)",
                centeredAtX: itemRect.midX,
                y: itemRect.minY + 3,
                font: .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
                color: active ? accentColor.withAlphaComponent(0.9) : NSColor(calibratedWhite: 0.1, alpha: 0.42)
            )
        }

        drawTextButton()
        drawDivider(atY: textButtonRect.minY - sectionGap / 2)

        for (i, cell) in swatchRects().enumerated() {
            let d: CGFloat = 15
            let dot = CGRect(x: cell.midX - d / 2, y: cell.midY - d / 2, width: d, height: d)
            Self.palette[i].color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            if i == activeColorIndex {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 1.6
                accentColor.setStroke()
                ring.stroke()
            }
        }

        let color = Self.palette[activeColorIndex].color
        for (i, cell) in widthRects().enumerated() {
            // Visual size only: 3 / 5 / 8 pt.
            let d = [3.0, 5.0, 8.0][min(i, 2)] as CGFloat
            let dot = CGRect(x: cell.midX - d / 2, y: cell.midY - d / 2, width: d, height: d)
            (currentTool == .highlighter ? color.withAlphaComponent(0.55) : color).setFill()
            NSBezierPath(ovalIn: dot).fill()
            if i == activeWidthIndex {
                let ring = NSBezierPath(ovalIn: CGRect(x: cell.midX - 7, y: cell.midY - 7, width: 14, height: 14))
                ring.lineWidth = 1.2
                accentColor.setStroke()
                ring.stroke()
            }
        }
    }

    private func drawDivider(atY y: CGFloat) {
        let rect = toolbarRect
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: rect.minX + 12, y: y))
        divider.line(to: CGPoint(x: rect.maxX - 12, y: y))
        divider.lineWidth = 1
        NSColor(calibratedWhite: 0, alpha: 0.12).setStroke()
        divider.stroke()
    }

    /// One-shot action, never "selected": a divider then a plain T.
    private func drawTextButton() {
        let itemRect = textButtonRect
        drawDivider(atY: itemRect.maxY + sectionGap / 2)
        drawCenteredLabel(
            "T",
            centeredAtX: itemRect.midX,
            y: itemRect.minY + 13,
            font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            color: NSColor(calibratedWhite: 0.15, alpha: 0.7)
        )
        drawCenteredLabel(
            "文字",
            centeredAtX: itemRect.midX,
            y: itemRect.minY + 2,
            font: .systemFont(ofSize: 8, weight: .medium),
            color: NSColor(calibratedWhite: 0.1, alpha: 0.42)
        )
    }

    /// Small vector icon for a tool, drawn to fit `rect`.
    private func drawGlyph(for tool: BoardTool, in rect: CGRect, color: NSColor) {
        let side = min(rect.width, rect.height) * 0.78
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        guard side > 2 else { return }

        let path = NSBezierPath()
        switch tool {
        case .pen:
            path.move(to: CGPoint(x: box.minX, y: box.minY + box.height * 0.32))
            path.curve(
                to: CGPoint(x: box.midX, y: box.minY + box.height * 0.58),
                controlPoint1: CGPoint(x: box.minX + box.width * 0.18, y: box.maxY),
                controlPoint2: CGPoint(x: box.midX - box.width * 0.14, y: box.minY)
            )
            path.curve(
                to: CGPoint(x: box.maxX, y: box.minY + box.height * 0.86),
                controlPoint1: CGPoint(x: box.midX + box.width * 0.16, y: box.maxY),
                controlPoint2: CGPoint(x: box.maxX - box.width * 0.16, y: box.minY + box.height * 0.2)
            )
        case .highlighter:
            let band = NSBezierPath()
            band.move(to: CGPoint(x: box.minX + side * 0.1, y: box.midY - side * 0.05))
            band.line(to: CGPoint(x: box.maxX - side * 0.1, y: box.midY + side * 0.05))
            band.lineWidth = side * 0.34
            band.lineCapStyle = .square
            NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 0.5).setStroke()
            band.stroke()
            path.move(to: CGPoint(x: box.minX + side * 0.1, y: box.midY - side * 0.05))
            path.line(to: CGPoint(x: box.maxX - side * 0.1, y: box.midY + side * 0.05))
        case .eraser:
            // Tilted block with a band marking the rubber end.
            let body = NSBezierPath(
                roundedRect: CGRect(x: -side * 0.22, y: -side * 0.46, width: side * 0.44, height: side * 0.92),
                xRadius: side * 0.08,
                yRadius: side * 0.08
            )
            body.move(to: CGPoint(x: -side * 0.22, y: -side * 0.12))
            body.line(to: CGPoint(x: side * 0.22, y: -side * 0.12))
            var transform = AffineTransform(translationByX: box.midX, byY: box.midY)
            transform.rotate(byDegrees: -45)
            body.transform(using: transform)
            path.append(body)
        case .lasso:
            let loop = NSBezierPath(ovalIn: CGRect(x: box.minX, y: box.midY - side * 0.1, width: side, height: side * 0.55))
            loop.setLineDash([2.5, 2], count: 2, phase: 0)
            loop.lineWidth = max(1.2, side * 0.09)
            color.setStroke()
            loop.stroke()
            path.move(to: CGPoint(x: box.minX + side * 0.3, y: box.midY - side * 0.08))
            path.curve(
                to: CGPoint(x: box.minX + side * 0.2, y: box.minY),
                controlPoint1: CGPoint(x: box.minX + side * 0.45, y: box.minY + side * 0.2),
                controlPoint2: CGPoint(x: box.minX + side * 0.1, y: box.minY + side * 0.2)
            )
        case .line:
            path.move(to: CGPoint(x: box.minX, y: box.minY))
            path.line(to: CGPoint(x: box.maxX, y: box.maxY))
        case .rectangle:
            path.appendRoundedRect(box.insetBy(dx: 0, dy: box.height * 0.12), xRadius: 2.5, yRadius: 2.5)
        case .ellipse:
            path.appendOval(in: box.insetBy(dx: 0, dy: box.height * 0.1))
        case .arrow:
            let start = CGPoint(x: box.minX, y: box.minY)
            let end = CGPoint(x: box.maxX, y: box.maxY)
            path.move(to: start)
            path.line(to: end)
            let head = side * 0.34
            path.move(to: end)
            path.line(to: CGPoint(x: end.x - head, y: end.y))
            path.move(to: end)
            path.line(to: CGPoint(x: end.x, y: end.y - head))
        }

        color.setStroke()
        path.lineWidth = max(1.2, side * 0.11)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawStatusStrip() {
        let rect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: statusHeight)
        NSColor(calibratedWhite: 0.965, alpha: 0.98).setFill()
        NSBezierPath(rect: rect).fill()

        NSColor(calibratedWhite: 0, alpha: 0.1).setStroke()
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        separator.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        separator.lineWidth = 1
        separator.stroke()

        let zen = interactionMode == .zen
        let accent = zen ? accentColor : NSColor.systemOrange
        let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let badge = interactionMode.badge
        let badgeWidth = textWidth(badge, font: badgeFont) + 16
        let badgeRect = CGRect(x: 14, y: (statusHeight - 19) / 2, width: badgeWidth, height: 19)
        // Solid, not tinted: the mode decides whether the trackpad writes or
        // moves the pointer, so it must be impossible to misread at a glance.
        accent.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()
        drawLabel(badge, at: CGPoint(x: badgeRect.minX + 8, y: badgeRect.minY + 3), font: badgeFont, color: .white)

        var x = badgeRect.maxX + 12
        let baseline: CGFloat = 10
        let bodyFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let mutedColor = NSColor(calibratedWhite: 0.1, alpha: 0.75)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        func item(_ text: String, font: NSFont = bodyFont, color: NSColor = mutedColor) {
            drawLabel(text, at: CGPoint(x: x, y: baseline), font: font, color: color)
            x += textWidth(text, font: font) + 12
        }

        var toolText = currentTool.name
        if currentTool.isFreehand || [.line, .rectangle, .ellipse, .arrow].contains(currentTool) {
            toolText += " · " + Self.palette[activeColorIndex].name
                + " · " + ["细", "中", "粗"][activeWidthIndex]
        }
        if currentTool == .eraser { toolText += eraseWholeStrokes ? " · 整笔" : " · 局部" }
        item(toolText)
        if zen, !drawOnContact { item("轻触定位 · 按下书写", color: accentColor) }
        if isLaserHeld { item("激光笔 · 不出墨", color: .systemRed) }
        item("\(Int((model.zoom * 100).rounded()))%", font: numberFont,
             color: isTwoFingerNavigating ? accentColor : mutedColor)

        let selected = currentSelection
        if !selected.isEmpty {
            item("已选 \(selected.count) 项 · 拖动移动 · ⌫ 删除 · C 换色", color: accentColor)
        }

        if zen && palmRejectionEnabled {
            var palmText = "防误触"
            if useContactSize && !MultitouchReader.shared.isAvailable { palmText += "（未授权输入监控）" }
            if !rejectedTouches.isEmpty { palmText += " · 已忽略 \(rejectedTouches.count)" }
            item(palmText, color: rejectedTouches.isEmpty ? mutedColor : .systemRed)
        }

        if showDebugInfo && zen && MultitouchReader.shared.isAvailable {
            var debug = String(format: "笔尖≤%.2fmm", penMaxMajor)
            if let shape = penShape {
                debug += String(format: " 当前 %.2fmm/%.2f", shape.majorAxis, shape.size)
            }
            if let finger = matchedFinger {
                debug += String(format: " · 压力 %.3f", finger.pressure)
                if let gate = pressureGate { debug += String(format: "/%.3f", gate.press) }
            }
            item(debug, font: numberFont)
        }

        let recorder = TouchRecorder.shared
        if recorder.isRecording, let label = recorder.label {
            let left = max(0, Int((recorder.endsAt - ProcessInfo.processInfo.systemUptime).rounded(.up)))
            item("● 录制 \(label) \(left)s · 面积帧 \(recorder.mtFrames)", color: .systemRed)
        }

        if let calibrationPrompt {
            item(calibrationPrompt, color: accentColor)
        } else if let flashText {
            item(flashText, color: accentColor)
        } else if isTwoFingerNavigating {
            item("双指移动 / 缩放", color: accentColor.withAlphaComponent(0.8))
        }

        let hints = zen
            ? "1–8 工具 · C 颜色 · W 粗细 · T 文字 · ⌘Z 撤销 · Esc 指针"
            : "指针模式：可点工具栏和笔记列表 · Esc 回到书写"
        let hintFont = NSFont.systemFont(ofSize: 10.5)
        let hintWidth = textWidth(hints, font: hintFont)
        if x + 16 + hintWidth < rect.maxX - 14 {
            drawLabel(hints, at: CGPoint(x: rect.maxX - hintWidth - 14, y: baseline + 0.5),
                      font: hintFont, color: NSColor(calibratedWhite: 0.1, alpha: 0.5))
        }
    }

    // MARK: - Drawing helpers

    private func applySoftShadow(blur: CGFloat, offsetY: CGFloat, alpha: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = CGSize(width: 0, height: offsetY)
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.set()
    }

    private func textWidth(_ string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private func drawLabel(_ string: String, at point: CGPoint, font: NSFont, color: NSColor) {
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawCenteredLabel(_ string: String, centeredAtX x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
        drawLabel(string, at: CGPoint(x: x - textWidth(string, font: font) / 2, y: y), font: font, color: color)
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

/// Bottom layer: shows the cached canvas image in a sublayer (GPU
/// composited) that pan/zoom can transform without re-rendering. `draw`
/// exists only for offscreen captures (`cacheDisplay`).
final class CanvasCacheView: NSView {
    private let imageLayer = CALayer()

    var image: CGImage? {
        didSet {
            withoutAnimation { imageLayer.contents = image }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.anchorPoint = .zero
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setImageTransform(_ transform: CGAffineTransform) {
        withoutAnimation { imageLayer.setAffineTransform(transform) }
    }

    override func updateLayer() {
        // Paper shows through where a panned image no longer covers.
        layer?.backgroundColor = NSColor.white.cgColor
    }

    override func layout() {
        super.layout()
        withoutAnimation {
            imageLayer.bounds = bounds
            imageLayer.position = .zero
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(image, in: bounds)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Top layer: transparent; draws the live stroke, cursor and chrome.
final class OverlayView: NSView {
    private weak var board: BoardTabView?

    init(board: BoardTabView) {
        self.board = board
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        board?.drawOverlays()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

