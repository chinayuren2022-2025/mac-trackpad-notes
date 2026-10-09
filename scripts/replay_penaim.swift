import AppKit

// How well PenAim predicts pen landings, replayed from real recordings:
// S=Sources/TrackpadStudio
// swiftc -parse-as-library scripts/replay_penaim.swift $S/{TrackpadCore,PalmRejection,PenAim}.swift -o /tmp/aim
// /tmp/aim [--left] file.jsonl...
// Every pen-down with the palm resting is predicted BEFORE it is learned
// from (the app's situation). Errors are reported in screen points for a
// writing area 850 pt wide (the default window), and as a share of the
// landings that fall inside the drawn marker.

@main
struct AimReplay {
    struct MT { let x: Double, y: Double, size: Double, maj: Double, min: Double }

    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let hand: PalmRejector.Hand = args.contains("--left") ? .left : .right
        args.removeAll { $0 == "--left" }
        let width: CGFloat = 850, height: CGFloat = 850 * 0.625
        var aim = PenAim(hand: hand)
        var errors: [CGFloat] = []
        var inside = 0
        var pens = 0
        for path in args {
            var rejector = PalmRejector()
            rejector.hand = hand
            var latest: [MT] = []
            var lastPen: Int?
            var previousAnchor: CGPoint?
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type == "mt" {
                    latest = (obj["c"] as? [[String: Any]] ?? []).compactMap {
                        let size = $0["size"] as? Double ?? 0
                        guard size > 0.05 else { return nil }
                        return MT(x: $0["x"] as! Double, y: $0["y"] as! Double, size: size,
                                  maj: $0["maj"] as! Double, min: $0["min"] as! Double)
                    }
                    continue
                }
                guard type == "ns", let t = obj["t"] as? Double else { continue }
                let all = (obj["touches"] as? [[String: Any]] ?? []).map { d in
                    TouchSample(id: d["id"] as! Int, pos: CGPoint(x: d["x"] as! Double, y: d["y"] as! Double),
                                deviceSize: .zero, resting: d["resting"] as? Bool == true)
                }
                let active = all.filter { !$0.resting }
                var shapes: [Int: PalmRejector.ContactShape] = [:]
                for touch in active {
                    guard let m = latest.min(by: { d2($0, touch) < d2($1, touch) }), d2(m, touch) < 0.08 * 0.08 else { continue }
                    shapes[touch.id] = .init(size: m.size, majorAxis: m.maj, minorAxis: m.min)
                }
                let out = rejector.process(active, shapes: shapes, now: t)
                // Same palm set as BoardTabView.updatePenAim.
                let palms = all.filter(\.resting) + out.rejected.filter { touch in
                    !(shapes[touch.id].map(PalmRejector.isFingerShaped) ?? false)
                }
                let anchor = PenAim.anchor(of: palms.map(\.pos), hand: hand)
                if let pen = out.pen, pen.id != lastPen {
                    pens += 1
                    if let anchor, previousAnchor != nil {
                        let guess = aim.predict(from: anchor)
                        let radius = min(70, max(14, aim.spread * width))
                        let error = hypot((guess.x - pen.pos.x) * width, (guess.y - pen.pos.y) * height)
                        errors.append(error)
                        if error <= radius { inside += 1 }
                        aim.learn(anchor: anchor, pen: pen.pos)
                    }
                }
                lastPen = out.pen?.id
                previousAnchor = anchor
            }
        }
        guard !errors.isEmpty else { print("no pen-downs with a resting palm"); return }
        func pct(_ values: [CGFloat], _ p: Double) -> Int {
            let sorted = values.sorted()
            return Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))])
        }
        let trained = Array(errors.dropFirst(5))
        print("pen-downs: \(pens), with palm resting: \(errors.count)")
        print("all:          median \(pct(errors, 0.5)) pt, 75% \(pct(errors, 0.75)) pt")
        if !trained.isEmpty {
            print("after 5 strokes: median \(pct(trained, 0.5)) pt, 75% \(pct(trained, 0.75)) pt")
        }
        print("landed inside the marker: \(inside)/\(errors.count)")
        print(String(format: "learned offset (%.3f, %.3f), spread %.3f", aim.offset.x, aim.offset.y, aim.spread))
    }

    static func d2(_ m: MT, _ t: TouchSample) -> Double {
        let dx = m.x - Double(t.pos.x), dy = m.y - Double(t.pos.y)
        return dx * dx + dy * dy
    }
}
