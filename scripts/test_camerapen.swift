import CoreGraphics
import Foundation

// Camera pen pieces without a camera:
// S=Sources/TrackpadStudio
// swiftc -parse-as-library scripts/test_camerapen.swift $S/{PadCalibration,TipTracker}.swift -o /tmp/tcam && /tmp/tcam

@main
struct CameraPenTests {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func main() {
        homography()
        calibration()
        tracker()
        cursor()
        reach()
        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func homography() {
        let truth = Homography(m: [1.2, 0.1, 0.05, -0.2, 0.9, 0.1, 0.3, -0.2, 1])
        let pts = (0..<12).map { CGPoint(x: Double($0 % 4) / 3, y: Double($0 / 4) / 2) }
        let fit = Homography.fit(pts.map { (from: $0, to: truth.map($0), weight: 1.0) })
        let worst = pts.map { p -> CGFloat in
            let a = fit!.map(p), b = truth.map(p)
            return hypot(a.x - b.x, a.y - b.y)
        }.max()!
        check(worst < 1e-9, "fit recovers a perspective map")
        let back = truth.inverse!.map(truth.map(CGPoint(x: 0.3, y: 0.7)))
        check(hypot(back.x - 0.3, back.y - 0.7) < 1e-9, "inverse round trip")
    }

    static func calibration() {
        let size = CGSize(width: 1920, height: 1440)
        let corners = [CGPoint(x: 1465, y: 95), CGPoint(x: 1575, y: 325), CGPoint(x: 1300, y: 640), CGPoint(x: 1268, y: 462)]
        var cal = PadCalibration(corners: corners, imageSize: size)!
        for (c, p) in zip(corners, PadCalibration.padCorners) {
            let q = cal.pad(at: c)
            check(hypot(q.x - p.x, q.y - p.y) < 1e-6, "corner \(p) maps onto the pad")
        }
        let mid = cal.image(at: CGPoint(x: 0.5, y: 0.5))
        let r = cal.pad(at: mid)
        check(hypot(r.x - 0.5, r.y - 0.5) < 1e-9, "pad ↔ image round trip")

        // A camera 6 px off from the dragged corners: touches pull it over.
        let shifted = Homography(m: [1, 0, 6.0 / 1920, 0, 1, 0, 0, 0, 1])
        for i in 0..<40 {
            let pad = CGPoint(x: Double(i % 8) / 7, y: Double(i / 8) / 4)
            let seen = cal.image(at: pad)
            let truth = CGPoint(x: shifted.map(CGPoint(x: seen.x / 1920, y: seen.y / 1440)).x * 1920, y: seen.y)
            cal.learn(image: truth, pad: pad)
        }
        let probe = cal.image(at: CGPoint(x: 0.5, y: 0.5))
        check(abs(probe.x - mid.x - 6) < 1.5, "learned the shift from touches (\(String(format: "%.1f", probe.x - mid.x)) px of 6)")
        check(!cal.isLost, "not lost while touches agree")
        for _ in 0..<8 { cal.learn(image: CGPoint(x: 100, y: 1300), pad: CGPoint(x: 0.5, y: 0.5)) }
        check(cal.isLost, "lost after touches far from the map (phone moved)")
        let count = cal.pairs.count
        cal.setCorners(corners)
        check(cal.pairs.isEmpty && !cal.isLost && count == 40, "new corners start over")
    }

    static func cursor() {
        var c = HoverCursor()
        // The cursor always shows 3 mm right of where the pen lands.
        let off = CGPoint(x: 3.0 / 124, y: 0)
        for i in 0..<10 {
            let land = CGPoint(x: 0.3 + Double(i) * 0.04, y: 0.5)
            var t = Double(i)
            for k in 0..<5 { _ = c.hover(CGPoint(x: land.x + off.x, y: land.y), at: t + Double(k) * 0.04) }
            t += 0.2
            _ = c.touch(land, at: t)
        }
        let shown = c.hover(CGPoint(x: 0.5 + off.x, y: 0.5), at: 100)
        check(HoverCursor.mm(shown, CGPoint(x: 0.5, y: 0.5)) < 0.5, "landing offset learned (\(String(format: "%.2f", HoverCursor.mm(shown, CGPoint(x: 0.5, y: 0.5)))) mm left)")
        // Jitter of ±1 mm while still: smoothed.
        var spread = 0.0
        var previous: CGPoint?
        for k in 0..<40 {
            let jitter = (k % 2 == 0 ? 1.0 : -1.0) / 124
            let p = c.hover(CGPoint(x: 0.5 + off.x + jitter, y: 0.5), at: 101 + Double(k) * 0.045)
            if let previous, k > 5 { spread = max(spread, HoverCursor.mm(p, previous)) }
            previous = p
        }
        check(spread < 1, "hover jitter of 2 mm smoothed to \(String(format: "%.2f", spread)) mm")
        // A steady 100 mm/s move: the cursor keeps up.
        var lag = 0.0
        for k in 0..<20 {
            let x = 0.3 + 100.0 / 124 * Double(k) * 0.045
            let p = c.hover(CGPoint(x: x + off.x, y: 0.5), at: 200 + Double(k) * 0.045)
            lag = HoverCursor.mm(p, CGPoint(x: x, y: 0.5))
        }
        check(lag < 4, "keeps up with a 100 mm/s move (\(String(format: "%.1f", lag)) mm behind)")
        let decoded = try! JSONDecoder().decode(HoverCursor.self, from: JSONEncoder().encode(c))
        check(decoded.bias == c.bias && decoded.biasSamples == c.biasSamples, "offset survives saving")
    }

    /// The writer hovers a while, aiming, then puts the pen down 8 mm ahead
    /// along the pen (the axis meets the pad there, not below the tip).
    static func reach() {
        var c = HoverCursor()
        let f = c.forward
        let ahead = CGPoint(x: 8 * f.dx / 124, y: 8 * f.dy / 76)
        var t = 0.0
        _ = c.touch(CGPoint(x: 0.5, y: 0.5), at: t)
        for i in 0..<12 {
            let tip = CGPoint(x: 0.3 + Double(i % 4) * 0.1, y: 0.4 + Double(i % 3) * 0.1)
            // Up for 1.5 s, still while aiming, then down along the pen
            // in the last 0.2 s onto the spot it pointed at.
            for k in 1...30 {
                let down = CGFloat(max(0, k - 26)) / 4
                _ = c.hover(CGPoint(x: tip.x + ahead.x * down, y: tip.y + ahead.y * down), at: t + 0.05 * Double(k))
            }
            t += 1.55
            _ = c.touch(CGPoint(x: tip.x + ahead.x, y: tip.y + ahead.y), at: t)
        }
        // Part of the 8 mm ends up in the landing offset (filter lag as the
        // pen comes down); the two together put the cursor on target below.
        check(c.reach > 5 && c.reach < 9, "reach along the pen learned (\(String(format: "%.1f", c.reach)) mm)")
        // Hovering a while: the cursor sits ahead of the tip, on the pen's line.
        var shown = CGPoint.zero
        for k in 1...20 { shown = c.hover(CGPoint(x: 0.5, y: 0.5), at: t + 0.05 * Double(k)) }
        let target = CGPoint(x: 0.5 + ahead.x, y: 0.5 + ahead.y)
        check(HoverCursor.mm(shown, target) < 1, "long hover: cursor where the pen points (\(String(format: "%.2f", HoverCursor.mm(shown, target))) mm off)")
        // A quick hop between letters: the tip is close to the pad, no reach.
        t += 1
        _ = c.touch(CGPoint(x: 0.5, y: 0.5), at: t)
        shown = c.hover(CGPoint(x: 0.52, y: 0.5), at: t + 0.1)
        let tipOnly = CGPoint(x: 0.52 + c.bias.x, y: 0.5 + c.bias.y)
        check(HoverCursor.mm(shown, tipOnly) < 0.1, "quick hop: no reach")
        var left = HoverCursor()
        left.leftHanded = true
        check(left.forward.dx > 0 && f.dx < 0 && left.forward.dy == f.dy, "left hand: the pen points the other way")
        // Settings saved before the reach existed still load.
        let old = try! JSONDecoder().decode(HoverCursor.self, from: #"{"bias":[0.01,0.02],"biasSamples":7}"#.data(using: .utf8)!)
        check(old.biasSamples == 7 && old.reach == 5 && old.reachSamples == 0, "older saved cursor loads with the default reach")
        let decoded = try! JSONDecoder().decode(HoverCursor.self, from: JSONEncoder().encode(c))
        check(decoded == c, "reach survives saving")
    }

    /// An asymmetric blob planted on noise: a tracker that convolves instead
    /// of correlating would match it mirrored and land off the tip.
    static func tracker() {
        let w = 400, h = 300
        var rng = SystemRandomNumberGenerator()
        func frame(tipAt t: CGPoint) -> [UInt8] {
            var px = (0..<(w * h)).map { _ in UInt8.random(in: 90...110, using: &rng) }
            for y in 0..<h {
                for x in 0..<w {
                    let dx = Double(x) - t.x, dy = Double(y) - t.y
                    // A pen: dark tip, a shaft running up-left, a bright cap.
                    if hypot(dx, dy) < 6 { px[y * w + x] = 20 }
                    if dx < 0, dx > -60, abs(dy - dx * 0.5) < 5 { px[y * w + x] = 40 }
                    if hypot(dx + 50, dy + 25) < 7 { px[y * w + x] = 230 }
                }
            }
            return px
        }
        var tracker = TipTracker()
        var a = frame(tipAt: CGPoint(x: 200, y: 150))
        a.withUnsafeBufferPointer { tracker.learn(LumaView(base: $0.baseAddress!, width: w, height: h, rowBytes: w), tip: CGPoint(x: 200, y: 150), shaft: CGVector(dx: -1, dy: -0.5)) }
        check(tracker.hasLearned, "learned a template")
        var worst: CGFloat = 0
        var all = true
        for step in 1...6 {
            let tip = CGPoint(x: 200 + Double(step) * 9, y: 150 - Double(step) * 5)
            a = frame(tipAt: tip)
            let seen = a.withUnsafeBufferPointer {
                tracker.locate(LumaView(base: $0.baseAddress!, width: w, height: h, rowBytes: w))
            }
            guard let seen else { all = false; continue }
            worst = max(worst, hypot(seen.point.x - tip.x, seen.point.y - tip.y))
        }
        check(all && worst < 3, "follows a moving asymmetric tip (worst \(String(format: "%.1f", worst)) px)")
        let blank = [UInt8](repeating: 100, count: w * h)
        let none = blank.withUnsafeBufferPointer {
            tracker.locate(LumaView(base: $0.baseAddress!, width: w, height: h, rowBytes: w))
        }
        check(none == nil, "no sighting in an empty picture")
    }
}
