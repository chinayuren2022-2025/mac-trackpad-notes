import CoreGraphics
import Foundation

/// One contact from a raw MultitouchSupport frame, as the connector sees it.
struct ConnectorContact {
    let id: Int
    /// Normalized pad position, 0..1, y-up.
    let pos: CGPoint
    let shape: PalmRejector.ContactShape
    /// MultitouchSupport state 3–4 (makeTouch / touching). Breaking and
    /// lingering contacts (5–6) are passed too, so a pen that fades for a few
    /// frames mid-stroke is not treated as lifted.
    var touching = true
}

/// Mouse actions in normalized pad coordinates; the connector maps them onto
/// the target window.
enum ConnectorAction: Equatable {
    case down(CGPoint)
    case drag(CGPoint)
    case up(CGPoint)
}

/// Pure pen/palm/gesture logic for driving another app. Same rules as the
/// canvas: one elected pen contact inks (PalmRejector, shape mode), and two
/// fingertips with no pen down are a navigation gesture — during which the
/// system's own scroll/zoom events are let through to the target app.
/// Exercised against recordings by scripts/test_connector.swift.
struct ConnectorCore {
    var rejector = PalmRejector()
    private(set) var navigating = false
    private var navigationIDs: Set<Int> = []
    private var navigationLostAt: TimeInterval?
    /// Last pen position while the virtual mouse button is down.
    private var penPoint: CGPoint?
    /// When the current pen contact last reported a touching state.
    private var penLastTouching: TimeInterval = 0
    /// A pen contact may fade (state 5/6) and return under the same ID:
    /// recorded fades were 17–107ms. Some are the tip skipping mid-stroke
    /// (it comes back where its speed predicts), others a quick lift to a new
    /// spot (it comes back far away). Only the first kind is joined — joining
    /// the second would draw a connecting line in the target app.
    static let penFadeTolerance: TimeInterval = 0.12
    /// Recent pen samples, for the speed that predicts where a skipping tip
    /// reappears.
    private var penTrail: [(t: TimeInterval, pos: CGPoint)] = []
    private var penFadedAt: TimeInterval?
    /// A new pen is confirmed on its second frame before the button goes
    /// down: a finger's first touch-down frame can read pen-sized (recorded:
    /// size 0.43, then 0.64), and the target app cannot take a click back.
    /// Positions seen meanwhile are replayed, so no ink is lost.
    private var pendingPenID: Int?
    private var pendingTrail: [CGPoint] = []

    var isPenDown: Bool { penPoint != nil }

    mutating func reset() -> [ConnectorAction] {
        let actions = releasePen()
        pendingPenID = nil
        pendingTrail = []
        rejector.reset()
        navigating = false
        navigationIDs = []
        navigationLostAt = nil
        return actions
    }

    mutating func process(_ frame: [ConnectorContact], now: TimeInterval) -> [ConnectorAction] {
        // A raw frame can list the same finger ID twice; keep the first.
        var seen = Set<Int>()
        var contacts = frame.filter { seen.insert($0.id).inserted }
        // Only touching contacts count, except a briefly fading pen, which is
        // held at its last position so the stroke stays one stroke.
        let penID = rejector.penID
        var splitStroke = false
        contacts = contacts.compactMap { contact in
            if contact.touching {
                if contact.id == penID {
                    if let fadedAt = penFadedAt, let held = penPoint {
                        let gap = now - fadedAt
                        let jump = hypot(contact.pos.x - held.x, contact.pos.y - held.y)
                        splitStroke = jump > max(0.02, 2 * penSpeed * gap)
                    }
                    penFadedAt = nil
                    penLastTouching = now
                }
                return contact
            }
            guard contact.id == penID, let held = penPoint,
                  now - penLastTouching < Self.penFadeTolerance else { return nil }
            if penFadedAt == nil { penFadedAt = now }
            return ConnectorContact(id: contact.id, pos: held, shape: contact.shape, touching: true)
        }
        let ids = Set(contacts.map(\.id))
        let shapes = Dictionary(contacts.map { ($0.id, $0.shape) }, uniquingKeysWith: { first, _ in first })

        if navigating {
            let palmJoined = contacts.contains { PalmRejector.isClearlyPalm($0.shape) }
            if ids == navigationIDs, !palmJoined {
                navigationLostAt = nil
                return []
            }
            // One finger dropped out for a moment: keep the gesture.
            if ids.count == 1, ids.isSubset(of: navigationIDs) {
                let lost = navigationLostAt ?? now
                navigationLostAt = lost
                if now - lost < 0.08 { return [] }
            }
            // The dropped finger came back under a new identity.
            if ids.count == 2, ids.intersection(navigationIDs).count == 1, !palmJoined,
               let newcomer = contacts.first(where: { !navigationIDs.contains($0.id) }),
               PalmRejector.isFingerShaped(newcomer.shape) {
                navigationIDs = ids
                navigationLostAt = nil
                return []
            }
            // Over: a finger still down must not start ink.
            rejector.lockOut(navigationIDs.intersection(ids))
            navigating = false
            navigationIDs = []
            navigationLostAt = nil
        } else if contacts.count == 2,
                  contacts.allSatisfy({ $0.pos.y > 0.06 && PalmRejector.isFingerShaped($0.shape) }),
                  rejector.canYieldToGesture(now: now) {
            let actions = releasePen()
            rejector.yieldToGesture()
            navigating = true
            navigationIDs = ids
            return actions
        }

        let touches = contacts.map {
            TouchSample(id: $0.id, pos: $0.pos, deviceSize: .zero, resting: false)
        }
        let out = rejector.process(touches, shapes: shapes, now: now)

        var actions: [ConnectorAction] = []
        // The target app has already drawn what was sent; a discarded stroke
        // (pen turned into a palm) can only be ended here, not taken back.
        if out.previousPenEnded || splitStroke { actions += releasePen() }
        if let pen = out.pen, penPoint == nil {
            if pendingPenID != pen.id {
                pendingPenID = pen.id
                pendingTrail = [pen.pos]
                return actions
            }
            pendingTrail.append(pen.pos)
            if !rejector.allowFinger, let shape = shapes[pen.id], PalmRejector.isFingerShaped(shape) {
                rejector.yieldToGesture()
                rejector.lockOut([pen.id])
                pendingPenID = nil
                pendingTrail = []
                return actions
            }
            pendingPenID = nil
            penLastTouching = now
            penTrail = [(now, pen.pos)]
            actions.append(.down(pendingTrail[0]))
            for point in pendingTrail.dropFirst() where point != pendingTrail[0] {
                actions.append(.drag(point))
            }
            penPoint = pen.pos
            pendingTrail = []
            return actions
        }
        if out.pen == nil { pendingPenID = nil }
        if let pen = out.pen {
            if pen.pos != penPoint {
                actions.append(.drag(pen.pos))
            }
            penPoint = pen.pos
            if penFadedAt == nil {
                penTrail.append((now, pen.pos))
                if penTrail.count > 5 { penTrail.removeFirst() }
            }
        } else {
            actions += releasePen()
        }
        return actions
    }

    /// Normalized pad units per second over the recent trail.
    private var penSpeed: CGFloat {
        guard let first = penTrail.first, let last = penTrail.last, last.t > first.t else { return 0 }
        return hypot(last.pos.x - first.pos.x, last.pos.y - first.pos.y) / CGFloat(last.t - first.t)
    }

    private mutating func releasePen() -> [ConnectorAction] {
        guard let point = penPoint else { return [] }
        penPoint = nil
        penFadedAt = nil
        return [.up(point)]
    }
}
