import AppKit

// Replays recorded MultitouchSupport frames through ConnectorCore — the exact
// input the Freeform connector uses — and checks the mouse action stream.
// swiftc -parse-as-library scripts/test_connector.swift \
//   Sources/TrackpadStudio/{TrackpadCore,PalmRejection,ConnectorCore}.swift -o /tmp/tc
// /tmp/tc calibration-or-touchlog-files.jsonl...

@main
struct ConnectorReplay {
    static func synthetic() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ name: String) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
        typealias S = PalmRejector.ContactShape
        let pen = S(size: 0.33, majorAxis: 6.6, minorAxis: 6.2)
        let finger = S(size: 0.8, majorAxis: 9.0, minorAxis: 8.0)
        let fingerOnset = S(size: 0.43, majorAxis: 7.8, minorAxis: 6.9)
        let palm = S(size: 4.0, majorAxis: 30, minorAxis: 15)
        func c(_ id: Int, _ x: CGFloat, _ y: CGFloat, _ s: S, touching: Bool = true) -> ConnectorContact {
            ConnectorContact(id: id, pos: CGPoint(x: x, y: y), shape: s, touching: touching)
        }
        do {
            var core = ConnectorCore()
            var a = core.process([c(1, 0.4, 0.6, pen)], now: 0)
            check(a.isEmpty, "pen: first frame waits for confirmation")
            a = core.process([c(1, 0.41, 0.6, pen)], now: 0.008)
            check(a == [.down(CGPoint(x: 0.4, y: 0.6)), .drag(CGPoint(x: 0.41, y: 0.6))], "pen: confirmed, first position replayed")
            a = core.process([c(1, 0.42, 0.6, pen), c(9, 0.7, 0.2, palm)], now: 0.016)
            check(a == [.drag(CGPoint(x: 0.42, y: 0.6))], "pen: palm landing mid-stroke ignored")
            a = core.process([c(9, 0.7, 0.2, palm)], now: 0.024)
            check(a == [.up(CGPoint(x: 0.42, y: 0.6))], "pen: lift releases")
        }
        do {
            var core = ConnectorCore()
            var all: [ConnectorAction] = []
            all += core.process([c(2, 0.5, 0.3, finger)], now: 0)
            all += core.process([c(2, 0.5, 0.3, finger), c(3, 0.57, 0.5, fingerOnset)], now: 0.008)
            all += core.process([c(2, 0.5, 0.3, finger), c(3, 0.57, 0.5, finger)], now: 0.016)
            all += core.process([c(2, 0.52, 0.32, finger), c(3, 0.59, 0.52, finger)], now: 0.024)
            check(all.isEmpty && core.navigating, "second finger's pen-sized touch-down sends no click; gesture starts")
        }
        do {
            var core = ConnectorCore()
            var t = 0.0, x: CGFloat = 0.3
            var all: [ConnectorAction] = []
            for _ in 0..<6 { all += core.process([c(1, x, 0.6, pen)], now: t); t += 0.008; x += 0.005 }
            for _ in 0..<5 { all += core.process([c(1, x, 0.6, pen, touching: false)], now: t); t += 0.008 }
            x += 0.025   // back where its speed predicts
            for _ in 0..<3 { all += core.process([c(1, x, 0.6, pen)], now: t); t += 0.008; x += 0.005 }
            all += core.process([], now: t)
            check(all.filter { if case .down = $0 { return true }; return false }.count == 1, "tip skipping mid-stroke stays one stroke")
        }
        do {
            var core = ConnectorCore()
            var t = 0.0
            var all: [ConnectorAction] = []
            for i in 0..<6 { all += core.process([c(1, 0.3 + CGFloat(i) * 0.001, 0.6, pen)], now: t); t += 0.008 }
            for _ in 0..<5 { all += core.process([c(1, 0.3, 0.6, pen, touching: false)], now: t); t += 0.008 }
            for _ in 0..<3 { all += core.process([c(1, 0.5, 0.4, pen)], now: t); t += 0.008 }
            all += core.process([], now: t)
            check(all.filter { if case .down = $0 { return true }; return false }.count == 2, "quick lift to a new spot becomes two strokes")
        }
        return failures
    }

    static func main() throws {
        var failures = 0
        if CommandLine.arguments.count == 1 { exit(synthetic() == 0 ? 0 : 1) }
        for path in CommandLine.arguments.dropFirst() {
            var core = ConnectorCore()
            var downs = 0, drags = 0, ups = 0, navFrames = 0, contactFrames = 0
            var penDown = false, sequenceOK = true
            var downYs: [Double] = []
            for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
                guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["type"] as? String == "mt", let t = obj["t"] as? Double else { continue }
                let contacts = (obj["c"] as? [[String: Any]] ?? []).compactMap { c -> ConnectorContact? in
                    let state = c["st"] as? Int ?? 0, size = c["size"] as? Double ?? 0
                    guard (3...6).contains(state), size > 0.05 else { return nil }
                    return ConnectorContact(
                        id: c["fid"] as! Int,
                        pos: CGPoint(x: c["x"] as! Double, y: c["y"] as! Double),
                        shape: .init(size: size, majorAxis: c["maj"] as! Double, minorAxis: c["min"] as! Double),
                        touching: state <= 4)
                }
                if !contacts.isEmpty { contactFrames += 1 }
                for action in core.process(contacts, now: t) {
                    switch action {
                    case let .down(p):
                        if ProcessInfo.processInfo.environment["DEBUG_DOWNS"] != nil {
                            print("  down at t=\(t) p=\(p) contacts=\(contacts.map { ($0.id, $0.touching, $0.shape.size, $0.shape.majorAxis, $0.shape.minorAxis) })")
                        }
                        if penDown { sequenceOK = false }
                        penDown = true; downs += 1; downYs.append(Double(p.y))
                    case .drag:
                        if !penDown { sequenceOK = false }
                        drags += 1
                    case .up:
                        if !penDown { sequenceOK = false }
                        penDown = false; ups += 1
                    }
                }
                if core.navigating { navFrames += 1 }
            }
            for action in core.reset() { if case .up = action { ups += 1; penDown = false } }
            let name = (path as NSString).lastPathComponent
            let balanced = sequenceOK && downs == ups
            if !balanced { failures += 1 }
            print("\(name)")
            print("  contact frames \(contactFrames) | strokes (down) \(downs), drags \(drags), up \(ups) | navigating frames \(navFrames) | sequence \(balanced ? "OK" : "BROKEN")")
            if !downYs.isEmpty {
                print("  stroke start y: " + downYs.map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
