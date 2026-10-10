import CoreGraphics

/// Evens out a finished freehand stroke. Recorded writing shows about 0.3 mm
/// of sideways hand tremor (4–15 Hz) that the screen magnifies about tenfold;
/// a Gaussian over arc length removes it without lag, since the whole stroke
/// is known once the pen lifts. Sharp turns (the tips of a w, the corners of
/// a z) split the stroke first, so they stay sharp.
enum StrokeSmoothing {
    /// - Parameter unit: canvas units per millimetre of trackpad.
    static func smoothed(
        _ samples: [BoardStrokeSample], unit: CGFloat,
        sigma: CGFloat = 1.0, cornerAngle: CGFloat = 70
    ) -> [BoardStrokeSample] {
        guard samples.count > 2, unit.isFinite, unit > 0 else { return samples }
        let step = 0.1 * unit
        let points = resample(samples, step: step)
        let reach = Int((1.0 * unit / step).rounded())
        guard points.count > 2 else { return samples }

        var pieces: [[BoardStrokeSample]] = []
        var start = 0
        for cut in corners(points, reach: reach, angle: cornerAngle) + [points.count - 1] {
            pieces.append(smooth(Array(points[start...cut]), sigma: sigma * unit, step: step))
            start = cut
        }
        var result = pieces[0]
        for piece in pieces.dropFirst() { result += piece.dropFirst() }
        return result
    }

    /// Points every `step` along the stroke, widths interpolated.
    static func resample(_ samples: [BoardStrokeSample], step: CGFloat) -> [BoardStrokeSample] {
        var result = [samples[0]]
        var carried: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let length = hypot(b.point.x - a.point.x, b.point.y - a.point.y)
            guard length > 0 else { continue }
            var at = step - carried
            while at <= length {
                let t = at / length
                result.append(BoardStrokeSample(
                    point: CGPoint(x: a.point.x + (b.point.x - a.point.x) * t,
                                   y: a.point.y + (b.point.y - a.point.y) * t),
                    width: a.width + (b.width - a.width) * t
                ))
                at += step
            }
            carried = length - (at - step)
        }
        // End exactly where the pen lifted.
        if let last = samples.last {
            if carried > step * 0.01 { result.append(last) } else { result[result.count - 1] = last }
        }
        return result
    }

    /// Indices where the direction over `reach` points before and after
    /// turns by more than `angle` degrees, at least 1.5 × reach apart.
    private static func corners(_ p: [BoardStrokeSample], reach r: Int, angle: CGFloat) -> [Int] {
        guard r > 0, p.count > 2 * r + 2 else { return [] }
        var turns: [(index: Int, degrees: CGFloat)] = []
        for i in r..<(p.count - r) {
            let a = CGPoint(x: p[i].point.x - p[i - r].point.x, y: p[i].point.y - p[i - r].point.y)
            let b = CGPoint(x: p[i + r].point.x - p[i].point.x, y: p[i + r].point.y - p[i].point.y)
            let na = hypot(a.x, a.y), nb = hypot(b.x, b.y)
            guard na > 0, nb > 0 else { continue }
            let cosine = max(-1, min(1, (a.x * b.x + a.y * b.y) / (na * nb)))
            let degrees = acos(cosine) * 180 / .pi
            if degrees >= angle { turns.append((i, degrees)) }
        }
        var cuts: [Int] = []
        for turn in turns.sorted(by: { $0.degrees > $1.degrees })
        where cuts.allSatisfy({ abs($0 - turn.index) * 2 > r * 3 }) {
            cuts.append(turn.index)
        }
        return cuts.sorted()
    }

    /// Gaussian over evenly spaced points; both ends stay put (the stroke is
    /// mirrored through each end point before filtering).
    private static func smooth(_ p: [BoardStrokeSample], sigma: CGFloat, step: CGFloat) -> [BoardStrokeSample] {
        guard p.count > 2, sigma > 0 else { return p }
        let k = min(Int(3 * sigma / step) + 1, p.count - 1)
        var weights = (-k...k).map { exp(-0.5 * pow(CGFloat($0) * step / sigma, 2)) }
        let total = weights.reduce(0, +)
        weights = weights.map { $0 / total }
        func point(_ i: Int) -> CGPoint {
            if i < 0 {
                let m = p[-i].point
                return CGPoint(x: 2 * p[0].point.x - m.x, y: 2 * p[0].point.y - m.y)
            }
            if i >= p.count {
                let m = p[2 * (p.count - 1) - i].point
                let end = p[p.count - 1].point
                return CGPoint(x: 2 * end.x - m.x, y: 2 * end.y - m.y)
            }
            return p[i].point
        }
        return p.indices.map { i in
            var x: CGFloat = 0, y: CGFloat = 0
            for (offset, w) in zip(-k...k, weights) {
                let q = point(i + offset)
                x += q.x * w
                y += q.y * w
            }
            return BoardStrokeSample(point: CGPoint(x: x, y: y), width: p[i].width)
        }
    }
}
