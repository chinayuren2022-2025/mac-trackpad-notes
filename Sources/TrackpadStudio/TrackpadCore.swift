import AppKit

// MARK: - Shared input model (contract — do not change shapes without updating SPEC.md)

struct TouchSample {
    let id: Int
    let pos: CGPoint          // normalized 0..1, origin bottom-left of the trackpad
    let deviceSize: CGSize    // physical trackpad size in points
    let resting: Bool
}

enum InputEvent {
    case touches([TouchSample])                    // full current set, emitted on every change
    case pressure(pressure: Double, stage: Int)    // Force Touch; only streams while physically clicked
    case click(down: Bool, locationInView: CGPoint)
    case drag(locationInView: CGPoint)
    case magnify(delta: Double)                    // pinch; scale factor step = (1 + delta)
    case rotate(degrees: Double)
    case scroll(dx: Double, dy: Double, phase: NSEvent.Phase, momentum: NSEvent.Phase)
    case key(chars: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
}

// MARK: - Event capture view
// Embed as the lowest, bounds-filling subview of a tab; add controls as siblings above it.

final class TouchCaptureView: NSView {
    var onEvent: ((InputEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }   // y-up, matches NSTouch.normalizedPosition

    init() {
        super.init(frame: .zero)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private func emit(_ event: NSEvent) {
        let samples = event.touches(matching: .touching, in: self).map {
            TouchSample(id: $0.identity.hash,
                        pos: $0.normalizedPosition,
                        deviceSize: $0.deviceSize,
                        resting: $0.isResting)
        }
        onEvent?(.touches(samples))
    }

    override func touchesBegan(with event: NSEvent) { emit(event) }
    override func touchesMoved(with event: NSEvent) { emit(event) }
    override func touchesEnded(with event: NSEvent) { emit(event) }
    override func touchesCancelled(with event: NSEvent) { emit(event) }

    override func pressureChange(with event: NSEvent) {
        onEvent?(.pressure(pressure: Double(event.pressure), stage: event.stage))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onEvent?(.click(down: true, locationInView: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        onEvent?(.click(down: false, locationInView: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        onEvent?(.drag(locationInView: convert(event.locationInWindow, from: nil)))
    }

    override func magnify(with event: NSEvent) { onEvent?(.magnify(delta: Double(event.magnification))) }
    override func rotate(with event: NSEvent) { onEvent?(.rotate(degrees: Double(event.rotation))) }

    override func scrollWheel(with event: NSEvent) {
        onEvent?(.scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                         phase: event.phase, momentum: event.momentumPhase))
    }

    override func keyDown(with event: NSEvent) {
        onEvent?(.key(chars: event.charactersIgnoringModifiers ?? "",
                      keyCode: event.keyCode, modifiers: event.modifierFlags))
    }
}

// MARK: - Remembered device size
// The physical trackpad size is only reported with the first touch; persist it
// so the pad outline uses the real aspect immediately on later launches.

enum DeviceSizeStore {
    private static let key = "trackpad.deviceSize"

    static func remember(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        UserDefaults.standard.set([Double(size.width), Double(size.height)], forKey: key)
    }

    static var recalled: CGSize? {
        guard let a = UserDefaults.standard.array(forKey: key) as? [Double], a.count == 2,
              a[0] > 0, a[1] > 0 else { return nil }
        return CGSize(width: a[0], height: a[1])
    }
}

// MARK: - Geometry helper

enum TrackpadGeometry {
    /// Rect with the trackpad's aspect ratio, centered in `bounds`, filling `fraction` of the fit.
    static func padRect(in bounds: CGRect, deviceSize: CGSize, fraction: CGFloat = 0.7) -> CGRect {
        let aspect = (deviceSize.width > 0 && deviceSize.height > 0)
            ? deviceSize.width / deviceSize.height : 1.6
        var w = bounds.width * fraction
        var h = w / aspect
        if h > bounds.height * fraction { h = bounds.height * fraction; w = h * aspect }
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Map a normalized (0..1, y-up) trackpad position into a view-space rect.
    static func map(_ normalized: CGPoint, into rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width,
                y: rect.minY + normalized.y * rect.height)
    }
}
