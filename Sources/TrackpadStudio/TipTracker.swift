import Accelerate
import CoreGraphics

/// 8-bit luminance as the camera delivers it (plane 0 of a 420f buffer).
struct LumaView {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let rowBytes: Int
}

/// Follows the pen tip through camera frames by its look, learned from the
/// frames in which the pen touches the pad (the calibration says exactly
/// where the tip is then). The learned patch is a strip along the pen body
/// (chrome cone and shaft), not a square around the tip: a square is mostly
/// pad, and the tip's reflection in the glass pad sits in it while the pen
/// touches, so a hovering square match follows the reflection. Matching is
/// normalized cross-correlation at half resolution near the last sighting.
/// Replayed 60 s recording (2026-10-10): cursor spikes (a frame off its
/// neighbours' line by > 5 mm) 56/512 with the square, 6/401 with the strip,
/// the score floor, the jump gate and `HoverCursor`.
struct TipTracker {
    /// The strip in camera pixels: from `behind` past the tip to `along`
    /// up the pen body, `side` either side of it.
    static let along: CGFloat = 70
    static let behind: CGFloat = 16
    static let side: CGFloat = 28
    static let keep = 3
    /// Below this the match is not trusted.
    static let minimumScore: Float = 0.6
    /// A weaker match further than this (camera pixels, widening with each
    /// miss) from the last sighting is a jump to something else.
    static let jumpGate: CGFloat = 40
    static let sureScore: Float = 0.8

    private struct Template {
        var pixels: [Float]
        var width: Int
        var height: Int
        /// Tip offset from the template centre, half-resolution pixels.
        var tip: CGPoint
    }

    private var templates: [Template] = []
    /// Last place the tip was seen, camera pixels.
    private(set) var last: CGPoint?
    private var misses = 0

    var hasLearned: Bool { !templates.isEmpty }

    mutating func reset() {
        templates = []
        last = nil
        misses = 0
    }

    /// The tip is at `tip` in this frame (the pen is touching); `shaft`
    /// points from the tip up the pen body, camera pixels.
    mutating func learn(_ image: LumaView, tip: CGPoint, shaft: CGVector) {
        let length = hypot(shaft.dx, shaft.dy)
        guard length > 0 else { return }
        let d = CGPoint(x: shaft.dx / length, y: shaft.dy / length), n = CGPoint(x: -d.y, y: d.x)
        let corners = [-Self.behind, Self.along].flatMap { a in [-Self.side, Self.side].map { b in
            CGPoint(x: d.x * a + n.x * b, y: d.y * a + n.y * b)
        } }
        // Odd sizes at half resolution, centred on the strip's middle.
        let rx = Int((corners.map(\.x).max()! - corners.map(\.x).min()!) / 4), ry = Int((corners.map(\.y).max()! - corners.map(\.y).min()!) / 4)
        let mid = CGPoint(x: (corners.map(\.x).max()! + corners.map(\.x).min()!) / 2,
                          y: (corners.map(\.y).max()! + corners.map(\.y).min()!) / 2)
        let cx = Int(((tip.x + mid.x - 0.5) / 2).rounded()), cy = Int(((tip.y + mid.y - 0.5) / 2).rounded())
        guard let (patch, w, h, _, _) = Self.halfRes(image, x0: cx - rx, y0: cy - ry, x1: cx + rx + 1, y1: cy + ry + 1),
              w == 2 * rx + 1, h == 2 * ry + 1, let normalized = Self.normalize(patch) else { return }
        let tipOffset = CGPoint(x: (tip.x - 0.5) / 2 - CGFloat(cx), y: (tip.y - 0.5) / 2 - CGFloat(cy))
        templates.append(Template(pixels: normalized, width: w, height: h, tip: tipOffset))
        if templates.count > Self.keep { templates.removeFirst(templates.count - Self.keep) }
        last = tip
        misses = 0
    }

    /// Best match within `search` camera pixels of the last sighting; a
    /// wider search after the tip has been missed for a while.
    mutating func locate(_ image: LumaView, search: CGFloat = 80) -> (point: CGPoint, score: Float)? {
        guard let last, !templates.isEmpty else { return nil }
        let reach = Int((misses > 3 ? search * 3 : search) / 2)
        let rx = templates.map { $0.width / 2 }.max()!, ry = templates.map { $0.height / 2 }.max()!
        // Search window in template-centre positions around the last tip.
        let cx = Int((last.x - 0.5) / 2), cy = Int((last.y - 0.5) / 2)
        let shift = templates.last!.tip
        let mx = cx - Int(shift.x.rounded()), my = cy - Int(shift.y.rounded())
        guard let (src, w, h, ox, oy) = Self.halfRes(
            image, x0: mx - reach - rx, y0: my - reach - ry, x1: mx + reach + rx + 1, y1: my + reach + ry + 1
        ), w > 2 * rx + 1, h > 2 * ry + 1 else { return nil }

        // Integral images for the window sums in the denominator.
        let iw = w + 1
        var sum = [Double](repeating: 0, count: iw * (h + 1)), sq = sum
        for y in 0..<h {
            var rs = 0.0, rq = 0.0
            for x in 0..<w {
                let v = Double(src[y * w + x])
                rs += v; rq += v * v
                sum[(y + 1) * iw + x + 1] = sum[y * iw + x + 1] + rs
                sq[(y + 1) * iw + x + 1] = sq[y * iw + x + 1] + rq
            }
        }

        var best: (x: CGFloat, y: CGFloat, score: Float)?
        for template in templates {
            let tx = template.width / 2, ty = template.height / 2
            let n = Double(template.width * template.height)
            func deviation(_ x: Int, _ y: Int) -> Float {
                let x0 = x - tx, y0 = y - ty, x1 = x + tx + 1, y1 = y + ty + 1
                let s = sum[y1 * iw + x1] - sum[y0 * iw + x1] - sum[y1 * iw + x0] + sum[y0 * iw + x0]
                let q = sq[y1 * iw + x1] - sq[y0 * iw + x1] - sq[y1 * iw + x0] + sq[y0 * iw + x0]
                return Float(max(q - s * s / n, 1).squareRoot())
            }
            let map = Self.correlate(src, w, h, template)
            var top: (x: Int, y: Int, score: Float)?
            for y in ty..<(h - ty) {
                for x in tx..<(w - tx) {
                    let score = map[y * w + x] / deviation(x, y)
                    if score > (top?.score ?? -1) { top = (x, y, score) }
                }
            }
            guard let top, top.score > (best?.score ?? -1) else { continue }
            // Sub-pixel peak: a parabola through the neighbours on each axis.
            func score(_ x: Int, _ y: Int) -> Float { map[y * w + x] / deviation(x, y) }
            func offset(_ a: Float, _ b: Float, _ c: Float) -> CGFloat {
                let d = a - 2 * b + c
                return d < 0 ? CGFloat(max(-0.5, min(0.5, 0.5 * (a - c) / d))) : 0
            }
            let dx = top.x > tx && top.x < w - tx - 1 ? offset(score(top.x - 1, top.y), top.score, score(top.x + 1, top.y)) : 0
            let dy = top.y > ty && top.y < h - ty - 1 ? offset(score(top.x, top.y - 1), top.score, score(top.x, top.y + 1)) : 0
            best = (CGFloat(ox + top.x) + dx + template.tip.x, CGFloat(oy + top.y) + dy + template.tip.y, top.score)
        }
        guard let best, best.score >= Self.minimumScore else { misses += 1; return nil }
        let point = CGPoint(x: best.x * 2 + 0.5, y: best.y * 2 + 0.5)
        if best.score < Self.sureScore,
           hypot(point.x - last.x, point.y - last.y) > Self.jumpGate * CGFloat(1 + misses) {
            misses += 1
            return nil
        }
        self.last = point
        misses = 0
        return (point, best.score)
    }

    /// Where to look next without a sighting (a touch moved the pen there).
    mutating func move(to point: CGPoint) {
        last = point
    }

    // MARK: Pixels

    /// Σ template · window at every position (template centred), via vImage.
    private static func correlate(_ src: [Float], _ w: Int, _ h: Int, _ template: Template) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        var source = src
        source.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { d in
                var inBuffer = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var outBuffer = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                template.pixels.withUnsafeBufferPointer { t in
                    _ = vImageConvolve_PlanarF(&inBuffer, &outBuffer, nil, 0, 0, t.baseAddress!,
                                               UInt32(template.height), UInt32(template.width), 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        return out
    }

    /// Zero mean, unit length; nil for a flat patch.
    private static func normalize(_ p: [Float]) -> [Float]? {
        let mean = p.reduce(0, +) / Float(p.count)
        let centred = p.map { $0 - mean }
        let norm = centred.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 1 ? centred.map { $0 / norm } : nil
    }

    /// 2×2 averages over half-resolution columns x0..<x1, rows y0..<y1,
    /// clipped to the image; returns the clipped origin too.
    private static func halfRes(
        _ image: LumaView, x0: Int, y0: Int, x1: Int, y1: Int
    ) -> ([Float], Int, Int, Int, Int)? {
        let hw = image.width / 2, hh = image.height / 2
        let ax = max(0, x0), ay = max(0, y0), bx = min(hw, x1), by = min(hh, y1)
        let w = bx - ax, h = by - ay
        guard w > 0, h > 0 else { return nil }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let r0 = image.base + (2 * (ay + y)) * image.rowBytes
            let r1 = r0 + image.rowBytes
            for x in 0..<w {
                let c = 2 * (ax + x)
                out[y * w + x] = (Float(r0[c]) + Float(r0[c + 1]) + Float(r1[c]) + Float(r1[c + 1])) * 0.25
            }
        }
        return (out, w, h, ax, ay)
    }
}

/// From tracker sightings to the cursor on the pad: removes the offset
/// learned at landings (mostly parallax: a raised tip looks farther from
/// the camera than the spot below it), reaches out along the pen to where
/// its axis meets the pad once the pen has been up a while, and smooths
/// with a One Euro filter (steady when the pen hovers, little lag when it
/// moves). Pad units.
/// One camera cannot see how high the tip is, so the reach is learned from
/// where the pen lands after hovering. Replayed: 0.3 s before a landing
/// after a long hover the cursor missed it by 5.8 mm (median) with the
/// reach, 11.8 mm without; quick hops between letters are unchanged.
struct HoverCursor: Codable, Equatable {
    var bias: CGPoint = .zero
    var biasSamples = 0
    /// How far ahead of the tip the pen's axis meets the pad while it
    /// hovers, millimetres.
    var reach: Double = 5
    var reachSamples = 0
    /// The pen points away from the writing hand: set from the palm hand.
    var leftHanded = false
    /// Pad size in millimetres, for the thresholds and the filter.
    static let padMM = CGSize(width: 124, height: 76)
    static let minCutoff: Double = 2
    static let beta: Double = 0.02
    /// Up for less than this the pen is hopping between letters, near the
    /// pad: no reach. Full reach after `reachFull`.
    static let reachStart: Double = 0.3
    static let reachFull: Double = 0.7
    /// Landings after at least this long up teach the reach.
    static let aimedAir: Double = 1

    private var shown: CGPoint?
    /// The reach included in `shown`, pad units.
    private var shownExtra: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var time: Double = 0
    private var touching = false
    private var lastTouch: Double?
    /// Recent sightings: time and the offset-corrected spot, no reach.
    private var recent: [(t: Double, p: CGPoint)] = []

    private enum CodingKeys: String, CodingKey { case bias, biasSamples, reach, reachSamples }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bias = try c.decode(CGPoint.self, forKey: .bias)
        biasSamples = try c.decode(Int.self, forKey: .biasSamples)
        reach = try c.decodeIfPresent(Double.self, forKey: .reach) ?? 5
        reachSamples = try c.decodeIfPresent(Int.self, forKey: .reachSamples) ?? 0
    }

    static func == (a: HoverCursor, b: HoverCursor) -> Bool {
        a.bias == b.bias && a.biasSamples == b.biasSamples && a.reach == b.reach && a.reachSamples == b.reachSamples
    }

    static func mm(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x) * padMM.width, Double(a.y - b.y) * padMM.height)
    }

    /// Unit vector from the pen body to its tip, in millimetres on the pad
    /// (x right, y toward the keyboard): matches `PadCalibration.shaft`.
    var forward: CGVector {
        let x = 0.04 * Self.padMM.width, y = 0.04 * Self.padMM.height, l = hypot(x, y)
        return CGVector(dx: (leftHanded ? x : -x) / l, dy: y / l)
    }

    /// The pen touches at `pad`. Returns true when the offset learned.
    mutating func touch(_ pad: CGPoint, at t: Double) -> Bool {
        defer { touching = true; shown = nil; lastTouch = t; recent = [] }
        guard !touching, let shown, t - time < 0.15 else { return false }
        let air = lastTouch.map { t - $0 } ?? 0
        learnReach(pad, at: t, air: air)
        // What the cursor would have shown without the offset or the reach.
        let seen = CGPoint(x: pad.x - (shown.x - shownExtra.x - bias.x), y: pad.y - (shown.y - shownExtra.y - bias.y))
        guard biasSamples < 5 || Self.mm(seen, bias) < 8 else { return false }
        let rate = max(0.1, 1 / CGFloat(biasSamples + 1))
        bias.x += (seen.x - bias.x) * rate
        bias.y += (seen.y - bias.y) * rate
        biasSamples += 1
        return true
    }

    /// After a long hover the writer aimed, then put the pen down: how far
    /// ahead along the pen the landing was from where the tip hovered.
    private mutating func learnReach(_ pad: CGPoint, at t: Double, air: Double) {
        guard air >= Self.aimedAir else { return }
        let aiming = recent.filter { $0.t >= t - 0.4 && $0.t <= t - 0.15 }
        guard !aiming.isEmpty else { return }
        let f = forward
        func split(_ p: CGPoint) -> (along: Double, side: Double) {
            let x = Double(pad.x - p.x) * Self.padMM.width, y = Double(pad.y - p.y) * Self.padMM.height
            return (x * f.dx + y * f.dy, abs(x * f.dy - y * f.dx))
        }
        let parts = aiming.map { split($0.p) }
        let along = parts.map(\.along).sorted()[parts.count / 2]
        let side = parts.map(\.side).sorted()[parts.count / 2]
        // Far off the pen's line: the tracker was on something else.
        guard along > -5, along < 30, side < 8 else { return }
        reach += (max(0, along) - reach) * max(0.2, 1 / Double(reachSamples + 1))
        reachSamples += 1
    }

    /// A sighting of the hovering tip; returns where to draw the cursor.
    mutating func hover(_ raw: CGPoint, at t: Double) -> CGPoint {
        touching = false
        let corrected = CGPoint(x: raw.x + bias.x, y: raw.y + bias.y)
        recent.append((t, corrected))
        recent.removeAll { $0.t < t - 0.5 }
        let up = lastTouch.map { t - $0 } ?? .infinity
        let ramp = min(1, max(0, (up - Self.reachStart) / (Self.reachFull - Self.reachStart)))
        let f = forward
        let extra = CGPoint(x: f.dx * reach * ramp / Self.padMM.width, y: f.dy * reach * ramp / Self.padMM.height)
        let p = CGPoint(x: corrected.x + extra.x, y: corrected.y + extra.y)
        guard let previous = shown, t - time < 0.15 else {
            shown = p; shownExtra = extra; velocity = .zero; time = t
            return p
        }
        let dt = max(0.001, t - time)
        func alpha(_ cutoff: Double) -> CGFloat { CGFloat(1 / (1 + 1 / (2 * .pi * cutoff * dt))) }
        let v = CGPoint(x: (p.x - previous.x) / dt, y: (p.y - previous.y) / dt)
        let a = alpha(10)
        velocity = CGPoint(x: velocity.x + (v.x - velocity.x) * a, y: velocity.y + (v.y - velocity.y) * a)
        let speed = hypot(Double(velocity.x) * Self.padMM.width, Double(velocity.y) * Self.padMM.height)
        let b = alpha(Self.minCutoff + Self.beta * speed)
        let next = CGPoint(x: previous.x + (p.x - previous.x) * b, y: previous.y + (p.y - previous.y) * b)
        shownExtra = CGPoint(x: shownExtra.x + (extra.x - shownExtra.x) * b, y: shownExtra.y + (extra.y - shownExtra.y) * b)
        shown = next
        time = t
        return next
    }
}
