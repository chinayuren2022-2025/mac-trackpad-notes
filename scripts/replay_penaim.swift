import AppKit

// How well PenAim predicts pen landings, replayed from real recordings:
// S=Sources/TrackpadStudio
// swiftc -parse-as-library scripts/replay_penaim.swift $S/{TrackpadCore,PalmRejection,PenAim}.swift -o /tmp/aim
// /tmp/aim [--left] file.jsonl|file.jsonl.gz|folder...
// A folder is searched for recordings (the continuous log folder works).
// Every pen-down is predicted BEFORE it is learned from (the app's
// situation), by the palm offset alone (the old marker) and by the full
// prediction with the carried lift point. Files that record the app's own
// pen choice are replayed with it; older ones re-run the palm rejector.
// Errors are millimetres on the pad.

@main
struct AimReplay {
    struct MT { let x: Double, y: Double, size: Double, maj: Double, min: Double }

    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let hand: PalmRejector.Hand = args.contains("--left") ? .left : .right
        args.removeAll { $0 == "--left" }
        let mm = CGSize(width: 124, height: 76)
        var aim = PenAim(hand: hand)
        var palmOnly = PenAim(hand: hand)
        var full: [CGFloat] = [], old: [CGFloat] = []
        var inside = 0, pens = 0
        func miss(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot((a.x - b.x) * mm.width, (a.y - b.y) * mm.height)
        }
        for path in recordings(args) {
            var rejector = PalmRejector()
            rejector.hand = hand
            var tracker = PenAimTracker()
            var latest: [MT] = []
            var lastPen: Int?
            var previousAnchor: CGPoint?
            for line in try read(path).split(separator: "\n") {
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
                let pen: TouchSample?, rejected: [TouchSample]
                if obj.keys.contains("pen") {
                    let id = obj["pen"] as? Int
                    let ids = Set(obj["rejected"] as? [Int] ?? [])
                    pen = active.first { $0.id == id }
                    rejected = active.filter { ids.contains($0.id) }
                } else {
                    let out = rejector.process(active, shapes: shapes, now: t)
                    pen = out.pen
                    rejected = out.rejected
                }
                // Same sets as BoardTabView.updatePenAim.
                let palms = all.filter(\.resting) + rejected.filter { touch in
                    !(shapes[touch.id].map(PalmRejector.isFingerShaped) ?? false)
                }
                let anchor = PenAim.anchor(of: palms.map(\.pos), hand: hand)
                let others = all.filter { $0.id != pen?.id }

                if let pen, pen.id != lastPen {
                    pens += 1
                    let guess = tracker.predict(aim, contacts: others, anchor: previousAnchor == nil ? nil : anchor, now: t)
                    if let guess, let anchor, previousAnchor != nil {
                        let error = miss(guess, pen.pos)
                        full.append(error)
                        old.append(miss(palmOnly.predict(from: anchor), pen.pos))
                        // The drawn disc, at about 10 screen points per millimetre.
                        if error <= min(3.6, max(1, aim.spread * mm.width * 0.6)) { inside += 1 }
                        palmOnly.learn(anchor: anchor, carried: nil, pen: pen.pos)
                    }
                }
                _ = tracker.update(pen: pen, contacts: others, anchor: anchor, now: t, aim: &aim)
                lastPen = pen?.id
                previousAnchor = anchor
            }
        }
        guard !full.isEmpty else { print("no pen-downs with a resting palm"); return }
        func pct(_ values: [CGFloat], _ p: Double) -> String {
            let sorted = values.sorted()
            return String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))])
        }
        print("pen-downs: \(pens), with palm resting: \(full.count)")
        print("palm offset only:  median \(pct(old, 0.5)) mm, 75% \(pct(old, 0.75)), 90% \(pct(old, 0.9))")
        print("with lift point:   median \(pct(full, 0.5)) mm, 75% \(pct(full, 0.75)), 90% \(pct(full, 0.9))")
        print("landed inside the marker: \(inside)/\(full.count)")
        print(String(format: "offset (%.3f, %.3f), bias (%.4f, %.4f), spread %.3f",
                     aim.offset.x, aim.offset.y, aim.bias.x, aim.bias.y, aim.spread))
    }

    /// Files named on the command line, folders searched for recordings.
    static func recordings(_ args: [String]) -> [String] {
        args.flatMap { arg -> [String] in
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: arg, isDirectory: &isFolder), isFolder.boolValue,
                  let walker = FileManager.default.enumerator(atPath: arg) else { return [arg] }
            return walker.compactMap { $0 as? String }
                .filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".jsonl.gz") }
                .sorted()
                .map { (arg as NSString).appendingPathComponent($0) }
        }
    }

    static func read(_ path: String) throws -> String {
        guard path.hasSuffix(".gz") else { return try String(contentsOfFile: path, encoding: .utf8) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func d2(_ m: MT, _ t: TouchSample) -> Double {
        let dx = m.x - Double(t.pos.x), dy = m.y - Double(t.pos.y)
        return dx * dx + dy * dy
    }
}
