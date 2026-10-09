import AppKit

// Replays recorded touchlog JSONL files through the shipped PalmRejector:
// swiftc -parse-as-library scripts/replay_touchlog.swift \
//   Sources/TrackpadStudio/{TrackpadCore,PalmRejection}.swift -o /tmp/replay
// /tmp/replay [--finger] file.jsonl...

@main
struct Replay {
    struct MT { let x: Double, y: Double, size: Double, maj: Double, min: Double }

    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let allowFinger = args.contains("--finger")
        args.removeAll { $0 == "--finger" }
        for path in args {
            var rejector = PalmRejector()
            rejector.allowFinger = allowFinger
            var latest: [MT] = []
            var activeFrames = 0, penFrames = 0, strokes: [(y: Double, frames: Int)] = []
            var lastPen: Int?
            var palmPenFrames = 0
            var firstSeen: [Int: Double] = [:]
            var pendingDelays: [Double] = []
            let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
            for line in lines {
                guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type == "mt" {
                    latest = (obj["c"] as? [[String: Any]] ?? []).compactMap {
                        let size = $0["size"] as? Double ?? 0
                        guard size > 0.05 else { return nil }   // same filter as MultitouchBridge
                        return MT(x: $0["x"] as! Double, y: $0["y"] as! Double, size: size,
                                  maj: $0["maj"] as! Double, min: $0["min"] as! Double)
                    }
                    continue
                }
                guard type == "ns", let t = obj["t"] as? Double else { continue }
                let touches = (obj["touches"] as? [[String: Any]] ?? []).compactMap { d -> TouchSample? in
                    guard d["resting"] as? Bool != true else { return nil }
                    return TouchSample(id: d["id"] as! Int,
                                       pos: CGPoint(x: d["x"] as! Double, y: d["y"] as! Double),
                                       deviceSize: .zero, resting: false)
                }
                var shapes: [Int: PalmRejector.ContactShape] = [:]
                var shapeOf: [Int: MT] = [:]
                for touch in touches {
                    guard let m = latest.min(by: { d2($0, touch) < d2($1, touch) }), d2(m, touch) < 0.08 * 0.08 else { continue }
                    shapeOf[touch.id] = m
                    shapes[touch.id] = .init(size: m.size, majorAxis: m.maj, minorAxis: m.min)
                }
                let out = rejector.process(touches, shapes: shapes, now: t)
                for touch in touches where firstSeen[touch.id] == nil { firstSeen[touch.id] = t }
                if let pen = out.pen, pen.id != lastPen, let seen = firstSeen[pen.id] {
                    pendingDelays.append(t - seen)
                }
                firstSeen = firstSeen.filter { id, _ in touches.contains { $0.id == id } }
                if !touches.isEmpty { activeFrames += 1 }
                if let pen = out.pen {
                    penFrames += 1
                    if let m = shapeOf[pen.id], PalmRejector.isClearlyPalm(.init(size: m.size, majorAxis: m.maj, minorAxis: m.min)) { palmPenFrames += 1 }
                    if lastPen != pen.id || out.previousPenEnded { strokes.append((Double(pen.pos.y), 0)) }
                    strokes[strokes.count - 1].frames += 1
                }
                lastPen = out.pen?.id
            }
            let name = (path as NSString).lastPathComponent
            print("\(name)\(allowFinger ? " [finger]" : "")")
            print("  frames with contact: \(activeFrames), inking frames: \(penFrames), strokes: \(strokes.count), inking on clear-palm shape: \(palmPenFrames)")
            let delayed = pendingDelays.filter { $0 > 0 }
            print("  strokes started late: \(delayed.count)/\(pendingDelays.count), delays ms: \(delayed.map { Int($0 * 1000) })")
            let ys = strokes.map { String(format: "%.2f", $0.y) }.joined(separator: " ")
            print("  stroke start y: \(ys)")
        }
    }

    static func d2(_ m: MT, _ t: TouchSample) -> Double {
        let dx = m.x - Double(t.pos.x), dy = m.y - Double(t.pos.y)
        return dx * dx + dy * dy
    }
}
