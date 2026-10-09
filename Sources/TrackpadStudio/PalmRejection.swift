import CoreGraphics
import Foundation

/// Elects at most one "pen" contact out of everything touching the pad; every
/// other contact is rejected until it lifts. Pure logic, no AppKit state, so
/// it can be exercised by scripts/test_palm.swift.
///
/// Signals, strongest first:
/// 1. Lock — once a contact is the pen it stays the pen until it lifts, so a
///    palm landing mid-stroke can never break or hijack the stroke. A contact
///    rejected once stays rejected until it lifts (a palm left on the pad after
///    the pen lifts never becomes the next pen).
/// 2. Contact shape (private MultitouchSupport) — `classify` decides pen vs
///    palm from size and ellipse axes. Calibrated on recorded data: a passive
///    stylus tip is small and round (size ≈0.33, major ≈6.5mm), a finger is
///    ≥8.5mm, and every palm contact — even the small heel at the pad edge —
///    is ≥9.3mm long. Palm-shaped contacts are rejected outright.
/// 3. Geometry — for a right hand the tip sits above and left of the palm
///    (normalized pad coordinates are y-up), mirrored for a left hand.
/// 4. Stillness — a pen that has not moved yields to a better-placed newcomer
///    (palm landed first, then the pen), and a long still contact that lifts
///    without moving is discarded instead of committed as a dot.
struct PalmRejector {
    enum Hand: String {
        case right
        case left
    }

    enum ContactKind {
        case pen
        case palm
    }

    struct ContactShape {
        var size: Double
        var majorAxis: Double
        var minorAxis: Double
    }

    /// Pen whitelist. Fingers are opt-in because a fingertip and the heel of a
    /// palm overlap in size; only their roundness separates them.
    static func classify(
        _ shape: ContactShape,
        penMaxMajor: Double = 8.0,
        allowFinger: Bool = false
    ) -> ContactKind {
        if shape.size <= 0.5, shape.majorAxis <= penMaxMajor {
            return .pen
        }
        if allowFinger, isFingerShaped(shape) {
            return .pen
        }
        return .palm
    }

    /// Round, fingertip-sized contact. Calibrated on a two-finger drag
    /// recording: light drag contacts are size 0.43–1.1, major 8.1–9.9mm,
    /// axis ratio ≤1.21 (p95) — the minor axis dips to ~7mm, so it is not a
    /// criterion. The pen tip (size ≤0.35) is too small; palm pieces of similar
    /// length are elongated or sit on the bottom edge (see the gesture start).
    static func isFingerShaped(_ shape: ContactShape) -> Bool {
        (0.45...1.3).contains(shape.size)
            && shape.majorAxis <= 11
            && shape.majorAxis / max(shape.minorAxis, 0.1) <= 1.3
    }

    /// Unambiguous palm: used to drop a contact already accepted as the pen,
    /// which should survive the odd borderline frame (fingers wobble near 9mm).
    static func isClearlyPalm(_ shape: ContactShape) -> Bool {
        shape.majorAxis > 12 || shape.size > 1.5
    }

    struct Output {
        var pen: TouchSample?
        var rejected: [TouchSample]
        /// The previous pen contact is over (lifted, taken over, or grew into
        /// a palm); the caller must close its stroke before feeding `pen`.
        var previousPenEnded = false
        /// Drop the previous pen's in-progress stroke instead of committing it.
        var discardPrevious = false
    }

    var hand: Hand = .right
    var penMaxMajor: Double = 8.0
    var allowFinger = false
    /// Max displacement (normalized pad units) for a contact to count as still.
    var stillTravel: CGFloat = 0.015
    /// A still contact held longer than this is a resting blob, not a dot.
    var restingDuration: TimeInterval = 0.35
    /// How much better placed (normalized y) a newcomer must be to take over.
    var takeoverMargin: CGFloat = 0.02

    private(set) var penID: Int?
    private var penStart: CGPoint = .zero
    private var penStartTime: TimeInterval = 0
    private var penMaxTravel: CGFloat = 0
    private var rejectedIDs: Set<Int> = []

    mutating func reset() {
        penID = nil
        rejectedIDs.removeAll()
    }

    /// `touches`: active (non-resting) contacts. `shapes`: nil when no shape
    /// data exists (geometry-only fallback); otherwise the shape of each touch
    /// the private reader matched — an unmatched touch is pending (not inked,
    /// not permanently rejected), since shape frames can lag.
    mutating func process(
        _ touches: [TouchSample],
        shapes: [Int: ContactShape]?,
        now: TimeInterval
    ) -> Output {
        let shapeMode = shapes != nil
        let (penMaxMajor, allowFinger) = (self.penMaxMajor, self.allowFinger)
        let kinds = (shapes ?? [:]).mapValues {
            Self.classify($0, penMaxMajor: penMaxMajor, allowFinger: allowFinger)
        }
        rejectedIDs.formIntersection(touches.map(\.id))
        var out = Output(pen: nil, rejected: [])

        var pen = penID.flatMap { id in touches.first { $0.id == id } }
        if let current = pen {
            penMaxTravel = max(penMaxTravel, distance(current.pos, penStart))
            // An accepted pen survives borderline frames; only a clear palm drops it.
            if let shape = shapes?[current.id], Self.isClearlyPalm(shape) {
                rejectedIDs.insert(current.id)
                endPen(&out, discard: true)
                pen = nil
            }
        } else if penID != nil {
            endPen(&out, discard: !shapeMode && isRestingBlob(now: now))
        }

        let clearlyPalm = Set((shapes ?? [:]).filter { Self.isClearlyPalm($0.value) }.keys)
        rejectedIDs.formUnion(clearlyPalm.subtracting(penID.map { [$0] } ?? []))
        // Pen-only mode: a contact that has looked like a fingertip is a
        // finger for good — a lifting finger shrinks through pen-tip size and
        // must not ink on its way up (the tip itself never reaches 0.45).
        if !allowFinger {
            let fingers = (shapes ?? [:]).filter { Self.isFingerShaped($0.value) }.keys
            rejectedIDs.formUnion(Set(fingers).subtracting(penID.map { [$0] } ?? []))
        }
        let candidates = touches.filter {
            $0.id != penID && !rejectedIDs.contains($0.id)
                && (!shapeMode || kinds[$0.id] == .pen)
        }
        let best = candidates.max { isBetter($1, than: $0, margin: 0) }

        if let best {
            if let current = pen {
                if penMaxTravel < stillTravel,
                   isBetter(best, than: current, margin: takeoverMargin) {
                    rejectedIDs.insert(current.id)
                    endPen(&out, discard: true)
                    pen = adopt(best, now: now)
                }
            } else {
                pen = adopt(best, now: now)
            }
        }

        for touch in touches where touch.id != penID {
            // With no pen down, a contact that is not clearly a palm (shape not
            // seen yet, or a borderline touch-down frame) may still turn into
            // the pen next frame, so it is hidden but not locked out.
            let pending = shapeMode && pen == nil && !clearlyPalm.contains(touch.id)
            if !pending { rejectedIDs.insert(touch.id) }
            out.rejected.append(touch)
        }
        out.pen = pen
        return out
    }

    /// A two-finger gesture may take over when no pen is down, or when the pen
    /// only just landed (the first finger of the pair, in finger mode).
    func canYieldToGesture(now: TimeInterval) -> Bool {
        penID == nil || (now - penStartTime < 0.25 && penMaxTravel < 0.03)
    }

    mutating func yieldToGesture() {
        penID = nil
    }

    /// Contacts that must not ink until they lift (a finger left behind when a
    /// two-finger gesture ends).
    mutating func lockOut(_ ids: Set<Int>) {
        rejectedIDs.formUnion(ids)
    }

    private mutating func adopt(_ touch: TouchSample, now: TimeInterval) -> TouchSample {
        penID = touch.id
        penStart = touch.pos
        penStartTime = now
        penMaxTravel = 0
        return touch
    }

    private mutating func endPen(_ out: inout Output, discard: Bool) {
        penID = nil
        out.previousPenEnded = true
        out.discardPrevious = out.discardPrevious || discard
    }

    private func isRestingBlob(now: TimeInterval) -> Bool {
        penMaxTravel < stillTravel && now - penStartTime > restingDuration
    }

    private func isBetter(_ a: TouchSample, than b: TouchSample, margin: CGFloat) -> Bool {
        placement(a) > placement(b) + margin
    }

    private func placement(_ touch: TouchSample) -> CGFloat {
        let lean: CGFloat = hand == .right ? -0.3 : 0.3
        return touch.pos.y + lean * touch.pos.x
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
