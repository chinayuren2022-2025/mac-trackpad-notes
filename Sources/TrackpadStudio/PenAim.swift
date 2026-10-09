import Foundation

/// Predicts where the pen will land before it touches. A capacitive pad
/// cannot sense a hovering tip, but the writing hand's palm rests on the pad
/// first, and the tip sits at a fairly steady offset from it. That offset is
/// learned from every stroke that starts with a palm down. All positions are
/// normalized trackpad coordinates (0…1, origin bottom-left).
struct PenAim: Codable, Equatable {
    var offset: CGPoint
    /// RMS distance between predicted and actual landings: the uncertainty.
    var spread: CGFloat
    var samples: Int

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
        CGPoint(x: min(1, max(0, anchor.x + offset.x)), y: min(1, max(0, anchor.y + offset.y)))
    }

    /// A stroke started at `pen` with the palm at `anchor`.
    mutating func learn(anchor: CGPoint, pen: CGPoint) {
        let seen = CGPoint(x: pen.x - anchor.x, y: pen.y - anchor.y)
        let error = hypot(seen.x - offset.x, seen.y - offset.y)
        // Once trained, a far-off landing is a repositioned hand, not a new habit.
        if samples >= 5, error > max(0.35, spread * 4) { return }
        // Average over the first strokes, then keep adapting quickly: the
        // wrist turns as the hand travels along a line.
        let rate = max(0.4, 1 / CGFloat(samples + 1))
        offset.x += (seen.x - offset.x) * rate
        offset.y += (seen.y - offset.y) * rate
        if samples > 0 {
            spread = sqrt(spread * spread * (1 - rate) + error * error * rate)
        }
        samples += 1
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
