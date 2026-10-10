import AVFoundation
import AppKit

/// Live camera picture with four handles to drag onto the trackpad's
/// corners. The phone is not in the same place every session, so this is
/// where the camera learns where the pad is; writing then refines it.
final class CameraAlignWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CameraAlignWindowController()

    private let alignView = CameraAlignView()
    private let cameraMenu = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var stateObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "摄像头对准"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 520, height: 420)
        super.init(window: window)
        window.delegate = self

        cameraMenu.target = self
        cameraMenu.action = #selector(chooseCamera(_:))
        let rotate = NSButton(title: "旋转画面", target: self, action: #selector(rotate(_:)))
        let reset = NSButton(title: "四角复位", target: self, action: #selector(resetCorners(_:)))
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString:
            "把四个圆点拖到触控板的四个角上（按你坐着看的方向：靠键盘一侧是“上”）。之后正常写字，每一笔都会让对准更准。"
            + "看不到触控板：打开“程序坞 → 桌上视角”（或 Photo Booth 的“桌上视角”）停在开始前的画面，再选“桌上视角摄像头”。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor

        let bar = NSStackView(views: [cameraMenu, rotate, reset, statusLabel])
        bar.spacing = 10
        let stack = NSStackView(views: [bar, hint, alignView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        alignView.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            alignView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        reloadCameras()
        let pen = CameraPen.shared
        pen.onPreview = { [weak self] preview in self?.alignView.show(preview) }
        pen.onState = { [weak self] text in self?.statusLabel.stringValue = text }
        statusLabel.stringValue = pen.status
        pen.previewing = true
        if !pen.isRunning { pen.start() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        CameraPen.shared.previewing = false
        CameraPen.shared.onPreview = nil
        // Opened just to align, with the hover marker off: release the camera.
        if !UserDefaults.standard.bool(forKey: "cameraPen.enabled") { CameraPen.shared.stop() }
    }

    private func reloadCameras() {
        cameraMenu.removeAllItems()
        let cameras = CameraPen.cameras()
        for camera in cameras {
            cameraMenu.addItem(withTitle: camera.localizedName)
            cameraMenu.lastItem?.representedObject = camera.uniqueID
        }
        if let current = CameraPen.preferredCamera(), let index = cameras.firstIndex(of: current) {
            cameraMenu.selectItem(at: index)
        }
    }

    @objc private func chooseCamera(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let device = CameraPen.cameras().first(where: { $0.uniqueID == id }) else { return }
        CameraPen.shared.start(device: device)
    }

    @objc private func rotate(_ sender: Any?) { alignView.rotateQuarter() }
    @objc private func resetCorners(_ sender: Any?) { alignView.resetCorners() }
}

/// The picture, the pad grid and the corner handles. Corners are kept in
/// camera pixels; only the drawing is rotated for a readable picture.
final class CameraAlignView: NSView {
    private var image: CGImage?
    private var tip: CGPoint?
    private var touch: CGPoint?
    /// Being dragged (camera pixels, BL TL TR BR); nil uses the calibration.
    private var dragCorners: [CGPoint]?
    private var dragging: Int?
    private var quarterTurns = UserDefaults.standard.integer(forKey: "cameraPen.rotation") {
        didSet { UserDefaults.standard.set(quarterTurns, forKey: "cameraPen.rotation") }
    }
    private static let labels = ["左下", "左上", "右上", "右下"]

    override var isFlipped: Bool { true }

    func show(_ preview: CameraPen.Preview) {
        image = preview.image
        tip = preview.tip
        touch = preview.touch
        needsDisplay = true
    }

    func rotateQuarter() {
        quarterTurns = (quarterTurns + 1) % 4
        needsDisplay = true
    }

    /// Handles back to a square in the middle of the picture, labels where
    /// the user sees them.
    func resetCorners() {
        guard let size = imageSize, let back = transform(for: size)?.inverted() else { return }
        let r = fitRect(for: size)
        let shown = [CGPoint(x: 0.3, y: 0.7), CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.3), CGPoint(x: 0.7, y: 0.7)]
        let corners = shown.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height).applying(back) }
        CameraPen.shared.setCorners(corners, imageSize: size)
        needsDisplay = true
    }

    private var imageSize: CGSize? { image.map { CGSize(width: $0.width, height: $0.height) } }

    private var corners: [CGPoint]? {
        if let dragCorners { return dragCorners }
        guard let cal = CameraPen.shared.calibration, cal.imageSize == imageSize else { return nil }
        return cal.corners
    }

    private func rotatedSize(_ size: CGSize) -> CGSize {
        quarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
    }

    private func fitRect(for size: CGSize) -> CGRect {
        let shown = rotatedSize(size)
        let scale = min(bounds.width / shown.width, bounds.height / shown.height)
        let w = shown.width * scale, h = shown.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Camera pixels (y down) → view points.
    private func transform(for size: CGSize) -> CGAffineTransform? {
        let r = fitRect(for: size)
        let scale = r.width / rotatedSize(size).width
        let turn: CGAffineTransform = switch quarterTurns {
        case 1: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        case 3: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        default: .identity
        }
        return turn.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: r.minX, y: r.minY))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image, let size = imageSize, let t = transform(for: size),
              let context = NSGraphicsContext.current?.cgContext else {
            let text = "等待摄像头画面…" as NSString
            text.draw(at: CGPoint(x: 20, y: 20), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14)])
            return
        }
        context.saveGState()
        context.concatenate(t)
        NSImage(cgImage: image, size: size).draw(in: CGRect(origin: .zero, size: size), from: .zero,
                                                   operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        context.restoreGState()

        guard let corners else { return }
        // The grid from what has been learned (or the dragged corners alone).
        let map = dragCorners == nil ? CameraPen.shared.calibration : PadCalibration(corners: corners, imageSize: size)
        if let map {
            let grid = NSBezierPath()
            for i in 0...4 {
                let f = CGFloat(i) / 4
                for line in [(CGPoint(x: f, y: 0), CGPoint(x: f, y: 1)), (CGPoint(x: 0, y: f), CGPoint(x: 1, y: f))] {
                    grid.move(to: map.image(at: line.0).applying(t))
                    for k in 1...16 {
                        let s = CGFloat(k) / 16
                        grid.line(to: map.image(at: CGPoint(x: line.0.x + (line.1.x - line.0.x) * s,
                                                            y: line.0.y + (line.1.y - line.0.y) * s)).applying(t))
                    }
                }
            }
            grid.lineWidth = 1
            NSColor.systemGreen.withAlphaComponent(0.7).setStroke()
            grid.stroke()
        }
        let outline = NSBezierPath()
        outline.move(to: corners[0].applying(t))
        for p in corners.dropFirst() { outline.line(to: p.applying(t)) }
        outline.close()
        outline.lineWidth = 1.5
        outline.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.systemYellow.setStroke()
        outline.stroke()

        if let touch { dot(touch.applying(t), radius: 5, color: .systemBlue) }
        if let tip { ring(tip.applying(t), radius: 10, color: .systemRed) }
        for (i, p) in corners.enumerated() {
            let q = p.applying(t)
            dot(q, radius: 8, color: .systemYellow)
            (Self.labels[i] as NSString).draw(
                at: CGPoint(x: q.x + 11, y: q.y - 9),
                withAttributes: [.foregroundColor: NSColor.systemYellow, .font: NSFont.boldSystemFont(ofSize: 13),
                                 .strokeColor: NSColor.black, .strokeWidth: -3]
            )
        }
        if let cal = CameraPen.shared.calibration {
            let text = cal.isLost
                ? "最近几笔和对准对不上：手机可能动过，请重新拖四角"
                : "已从书写中学习 \(cal.pairs.count) 个点" as NSString
            (text as NSString).draw(
                at: CGPoint(x: 12, y: bounds.height - 26),
                withAttributes: [.foregroundColor: cal.isLost ? NSColor.systemRed : NSColor.white,
                                 .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                 .strokeColor: NSColor.black, .strokeWidth: -3]
            )
        }
    }

    private func dot(_ p: CGPoint, radius: CGFloat, color: NSColor) {
        let path = NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        color.setFill()
        path.fill()
        NSColor.black.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func ring(_ p: CGPoint, radius: CGFloat, color: NSColor) {
        let path = NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        path.lineWidth = 2.5
        color.setStroke()
        path.stroke()
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        guard let size = imageSize, let t = transform(for: size) else { return }
        if corners == nil { resetCorners() }
        guard let corners else { return }
        let p = convert(event.locationInWindow, from: nil)
        let nearest = corners.indices.min { hypot(corners[$0].applying(t).x - p.x, corners[$0].applying(t).y - p.y)
            < hypot(corners[$1].applying(t).x - p.x, corners[$1].applying(t).y - p.y) }
        guard let nearest, hypot(corners[nearest].applying(t).x - p.x, corners[nearest].applying(t).y - p.y) < 30 else { return }
        dragging = nearest
        dragCorners = corners
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging, let size = imageSize, let back = transform(for: size)?.inverted() else { return }
        let p = convert(event.locationInWindow, from: nil).applying(back)
        dragCorners?[dragging] = CGPoint(x: min(size.width, max(0, p.x)), y: min(size.height, max(0, p.y)))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragging != nil, let dragCorners, let size = imageSize {
            CameraPen.shared.setCorners(dragCorners, imageSize: size)
        }
        dragging = nil
        dragCorners = nil
        needsDisplay = true
    }
}
