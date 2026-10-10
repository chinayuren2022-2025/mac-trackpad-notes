import CoreGraphics
import Foundation

// swiftc -parse-as-library scripts/test_smoothing.swift $S/{BoardModel,BoardArchive,InkRenderer,StrokeSmoothing}.swift -o /tmp/tsm && /tmp/tsm

@main
struct TestSmoothing {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "PASS" : "FAIL", name)
        if !ok { failures += 1 }
    }
    static func samples(_ points: [CGPoint]) -> [BoardStrokeSample] {
        points.map { BoardStrokeSample(point: $0, width: 2) }
    }
    static func distance(_ p: CGPoint, toPolyline line: [CGPoint]) -> CGFloat {
        zip(line, line.dropFirst()).map { a, b -> CGFloat in
            let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let len2 = d.x * d.x + d.y * d.y
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / len2)) : 0
            return hypot(p.x - a.x - d.x * t, p.y - a.y - d.y * t)
        }.min() ?? .infinity
    }

    static func main() {
        var rng = SystemRandomNumberGenerator()
        // Units: 1 = 1 mm. A 40 mm line written with 0.3 mm of sideways tremor.
        let noisy = (0...400).map { i -> CGPoint in
            let x = CGFloat(i) * 0.1
            return CGPoint(x: x, y: 0.3 * sin(x * 2 * .pi / 3) + CGFloat.random(in: -0.05...0.05, using: &rng))
        }
        let out = StrokeSmoothing.smoothed(samples(noisy), unit: 1).map(\.point)
        let rms = { (p: [CGPoint]) in sqrt(p.map { $0.y * $0.y }.reduce(0, +) / CGFloat(p.count)) }
        check(rms(out) < rms(noisy) * 0.5, String(format: "tremor on a line: rms %.3f -> %.3f mm", rms(noisy), rms(out)))
        check(hypot(out.first!.x - noisy.first!.x, out.first!.y - noisy.first!.y) < 1e-6
              && hypot(out.last!.x - noisy.last!.x, out.last!.y - noisy.last!.y) < 1e-6, "end points stay put")

        // A V: the tip must stay sharp.
        let v = (0...100).map { CGPoint(x: CGFloat($0) * 0.1, y: CGFloat($0) * 0.2) }
            + (1...100).map { CGPoint(x: 10 + CGFloat($0) * 0.1, y: 20 - CGFloat($0) * 0.2) }
        let vOut = StrokeSmoothing.smoothed(samples(v), unit: 1).map(\.point)
        let tip = vOut.max { $0.y < $1.y }!
        check(hypot(tip.x - 10, tip.y - 20) < 0.2, String(format: "corner kept: tip off by %.3f mm", hypot(tip.x - 10, tip.y - 20)))

        // A circle (no corners): stays a circle of the same size.
        let circle = (0...300).map { i -> CGPoint in
            let a = CGFloat(i) / 300 * 2 * .pi
            return CGPoint(x: 5 * cos(a), y: 5 * sin(a))
        }
        let radii = StrokeSmoothing.smoothed(samples(circle), unit: 1).map { hypot($0.point.x, $0.point.y) }
        check(radii.allSatisfy { abs($0 - 5) < 0.15 }, String(format: "5 mm circle keeps its radius (%.2f–%.2f)", radii.min()!, radii.max()!))

        // Short dots and two-point strokes come back unchanged.
        let dot = samples([CGPoint(x: 1, y: 1), CGPoint(x: 1.05, y: 1)])
        check(StrokeSmoothing.smoothed(dot, unit: 1).map(\.point) == dot.map(\.point), "two-point stroke unchanged")

        // Widths follow the stroke.
        let ramp = (0...100).map { BoardStrokeSample(point: CGPoint(x: CGFloat($0) * 0.2, y: 0), width: 1 + CGFloat($0) / 100) }
        let widths = StrokeSmoothing.smoothed(ramp, unit: 1).map(\.width)
        check(abs(widths.first! - 1) < 0.01 && abs(widths.last! - 2) < 0.01, "widths interpolated")

        // Canvas scale: the same stroke at 10 units per mm smooths the same.
        let scaled = noisy.map { CGPoint(x: $0.x * 10, y: $0.y * 10) }
        let scaledOut = StrokeSmoothing.smoothed(samples(scaled), unit: 10).map(\.point)
        check(abs(rms(scaledOut) / 10 - rms(out)) < 0.02, "scale independent")

        if CommandLine.arguments.count > 1 {
            // Recorded strokes vs the Python prototype: [[input], [expected]] per stroke, mm.
            let data = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[[[Double]]]]
            var worst: CGFloat = 0
            for pair in data {
                let input = pair[0].map { CGPoint(x: $0[0], y: $0[1]) }
                let expected = pair[1].map { CGPoint(x: $0[0], y: $0[1]) }
                let got = StrokeSmoothing.smoothed(samples(input), unit: 1).map(\.point)
                if expected.count > 1 { worst = max(worst, got.map { distance($0, toPolyline: expected) }.max() ?? 0) }
            }
            // 0.1 mm is under a pixel on screen; the two resample a stroke's last
            // tenth of a millimetre differently.
            check(worst < 0.1, String(format: "%d recorded strokes match the prototype (worst %.3f mm)", data.count, worst))
        }
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
