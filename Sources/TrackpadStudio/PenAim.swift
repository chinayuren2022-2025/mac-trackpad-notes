import Foundation

/// Predicts where the pen will land before it touches. A capacitive pad
/// cannot sense a hovering tip, but the writing hand's palm rests on the pad
/// first, and the tip sits at a fairly steady offset from it. That offset is
/// learned from every stroke that starts with a palm down.
///
/// Between strokes there is a better clue: where the pen just lifted. The
/// hand moves as one piece, so the lift point carried along by the palm's
/// slide since then (`PenAimTracker.carried`) lands closer; what is left is
/// the fingers moving the tip within the hand, which the pad cannot see.
/// Replayed continuous logs (215 pen-downs): median miss 3.3 mm blending
/// both, against 4.1 mm for the palm offset alone. All positions are
/// normalized trackpad coordinates (0…1, origin bottom-left).
struct PenAim: Codable, Equatable {
    var offset: CGPoint
    /// RMS distance between predicted and actual landings: the uncertainty.
    var spread: CGFloat
    var samples: Int
    /// Mean of landing minus the carried lift point: the typical step from
    /// one stroke's end to the next one's start (rightward, for writing).
    var bias: CGPoint = .zero
    var carriedSamples = 0

    /// Weight of the carried lift point when both clues exist.
    static let carriedWeight: CGFloat = 0.7

    init(hand: PalmRejector.Hand) {
        // Untrained guess, from the author's recordings: the tip a quarter of
        // the pad inward of the palm's leading edge and a little higher.
        offset = CGPoint(x: hand == .left ? 0.26 : -0.26, y: 0.38)
        spread = 0.1
        samples = 0
    }

    /// The palm contact nearest the pen side (leftmost for a right-handed
    /// writer). The hand touches down in several blobs that come and go; the
    /// one closest to the tip moves with it, their centroid jumps. Replayed
    /// recordings: median miss 46 pt vs 113 pt for the centroid
    /// (writing area 850 pt wide; `scripts/replay_penaim.swift`).
    static func anchor(of palms: [CGPoint], hand: PalmRejector.Hand) -> CGPoint? {
        hand == .left ? palms.max { $0.x < $1.x } : palms.min { $0.x < $1.x }
    }

    func predict(from anchor: CGPoint) -> CGPoint {
        clamp(CGPoint(x: anchor.x + offset.x, y: anchor.y + offset.y))
    }

    /// Best guess from whichever clues exist: the palm `anchor`, and the
    /// lift point `carried` along with the hand.
    func predict(anchor: CGPoint?, carried: CGPoint?) -> CGPoint? {
        let fromPalm = anchor.map(predict(from:))
        guard let carried else { return fromPalm }
        let fromLift = clamp(CGPoint(x: carried.x + bias.x, y: carried.y + bias.y))
        guard let fromPalm else { return fromLift }
        let w = Self.carriedWeight
        return CGPoint(x: fromLift.x * w + fromPalm.x * (1 - w), y: fromLift.y * w + fromPalm.y * (1 - w))
    }

    /// A stroke started at `pen`, with the palm at `anchor` and the last
    /// lift point carried to `carried` (either may be missing).
    mutating func learn(anchor: CGPoint?, carried: CGPoint?, pen: CGPoint) {
        if let guess = predict(anchor: anchor, carried: carried), samples + carriedSamples > 0 {
            let error = hypot(guess.x - pen.x, guess.y - pen.y)
            // A far-off landing is a repositioned hand; it says nothing
            // about how sure the marker should look.
            if error < 0.35 { spread = sqrt(spread * spread * 0.9 + error * error * 0.1) }
        }
        if let anchor { learn(anchor: anchor, pen: pen) }
        if let carried {
            let seen = CGPoint(x: pen.x - carried.x, y: pen.y - carried.y)
            if carriedSamples < 5 || hypot(seen.x - bias.x, seen.y - bias.y) < 0.2 {
                // A plain mean at first, then slowly forgetting.
                let rate = max(0.05, 1 / CGFloat(carriedSamples + 1))
                bias.x += (seen.x - bias.x) * rate
                bias.y += (seen.y - bias.y) * rate
                carriedSamples += 1
            }
        }
    }

    /// The palm-offset clue on its own.
    private mutating func learn(anchor: CGPoint, pen: CGPoint) {
        let seen = CGPoint(x: pen.x - anchor.x, y: pen.y - anchor.y)
        let error = hypot(seen.x - offset.x, seen.y - offset.y)
        // Once trained, a far-off landing is a repositioned hand, not a new habit.
        if samples >= 5, error > max(0.35, spread * 4) { return }
        // Average over the first strokes, then keep adapting quickly: the
        // wrist turns as the hand travels along a line.
        let rate = max(0.4, 1 / CGFloat(samples + 1))
        offset.x += (seen.x - offset.x) * rate
        offset.y += (seen.y - offset.y) * rate
        samples += 1
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y)))
    }

    // Saved before bias existed: fill in the new fields.
    private enum CodingKeys: String, CodingKey { case offset, spread, samples, bias, carriedSamples }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decode(CGPoint.self, forKey: .offset)
        spread = try c.decode(CGFloat.self, forKey: .spread)
        samples = try c.decode(Int.self, forKey: .samples)
        bias = try c.decodeIfPresent(CGPoint.self, forKey: .bias) ?? .zero
        carriedSamples = try c.decodeIfPresent(Int.self, forKey: .carriedSamples) ?? 0
    }

    // MARK: Persistence (one per writing hand)

    private static func key(_ hand: PalmRejector.Hand) -> String { "penAim." + hand.rawValue }

    static func load(hand: PalmRejector.Hand) -> PenAim {
        guard let data = UserDefaults.standard.data(forKey: key(hand)),
              let aim = try? JSONDecoder().decode(PenAim.self, from: data) else { return PenAim(hand: hand) }
        return aim
    }

    func save(hand: PalmRejector.Hand) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(hand))
        }
    }
}

/// Between strokes: where the pen lifted and where every other contact was
/// at that moment, so the hand's slide since then can be added to it.
struct PenAimTracker {
    private struct Seen {
        let id: Int
        let pen: CGPoint
        let contacts: [Int: CGPoint]
        let time: TimeInterval
    }
    /// A lift older than this no longer predicts the next landing.
    static let maxAir: TimeInterval = 1.5

    private var lastSeen: Seen?
    private var lift: Seen?
    /// The palm anchor one frame earlier: the offset is learned only when
    /// the palm was down before the pen.
    private var previousAnchor: CGPoint?

    var liftTime: TimeInterval? { lift?.time }

    /// The lift point moved by the mean slide of the contacts present both
    /// then and now; nil without a recent lift or a shared contact.
    func carried(contacts: [TouchSample], now: TimeInterval) -> CGPoint? {
        guard let lift, now - lift.time < Self.maxAir else { return nil }
        var dx: CGFloat = 0, dy: CGFloat = 0, n: CGFloat = 0
        for contact in contacts {
            guard let then = lift.contacts[contact.id] else { continue }
            dx += contact.pos.x - then.x
            dy += contact.pos.y - then.y
            n += 1
        }
        guard n > 0 else { return nil }
        return CGPoint(x: lift.pen.x + dx / n, y: lift.pen.y + dy / n)
    }

    func predict(_ aim: PenAim, contacts: [TouchSample], anchor: CGPoint?, now: TimeInterval) -> CGPoint? {
        aim.predict(anchor: anchor, carried: carried(contacts: contacts, now: now))
    }

    /// One touch frame: `pen` as elected, `contacts` every other touch.
    /// Returns true when `aim` learned from a pen-down (time to save it).
    mutating func update(
        pen: TouchSample?, contacts: [TouchSample], anchor: CGPoint?,
        now: TimeInterval, aim: inout PenAim
    ) -> Bool {
        var learned = false
        if let pen {
            if pen.id != lastSeen?.id {
                // The pen can hand over to a new contact without a gap.
                if let lastSeen { lift = lastSeen }
                let carried = carried(contacts: contacts, now: now)
                let palm = previousAnchor == nil ? nil : anchor
                if palm != nil || carried != nil {
                    aim.learn(anchor: palm, carried: carried, pen: pen.pos)
                    learned = true
                }
                lift = nil
            }
            lastSeen = Seen(
                id: pen.id, pen: pen.pos,
                contacts: Dictionary(contacts.map { ($0.id, $0.pos) }, uniquingKeysWith: { a, _ in a }),
                time: now
            )
        } else if let seen = lastSeen {
            lift = seen
            lastSeen = nil
        }
        previousAnchor = anchor
        return learned
    }
}
