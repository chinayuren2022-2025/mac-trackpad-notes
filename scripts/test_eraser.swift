import AppKit

// swiftc -parse-as-library scripts/test_eraser.swift Sources/TrackpadStudio/{BoardModel,BoardArchive,TrackpadCore,PalmRejection}.swift -o /tmp/test_eraser

@main
struct EraserChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print((ok ? "PASS " : "FAIL ") + name)
        if !ok { failures += 1 }
    }
    static func stroke(_ pts: [(CGFloat, CGFloat)]) -> BoardElement {
        .stroke(samples: pts.map { BoardStrokeSample(point: CGPoint(x: $0.0, y: $0.1), width: 2) }, color: .white)
    }

    static func main() {
        let c = NSColor.white
        let m = BoardModel()
        m.append(stroke([(0, 0), (100, 0)]))                                  // 0 horizontal stroke
        m.append(stroke([(0, 50), (100, 50)]))                                // 1 second stroke
        m.append(.rectangle(rect: CGRect(x: 200, y: 0, width: 100, height: 100), width: 2, color: c))
        m.append(.ellipse(rect: CGRect(x: 400, y: 0, width: 100, height: 100), width: 2, color: c))

        // Fast eraser swipe crossing stroke 0 between samples: segment test catches it.
        var hit = m.erase(from: CGPoint(x: 50, y: -30), to: CGPoint(x: 50, y: 30), radius: 5, recordingUndo: true)
        check(hit && m.elements.count == 3, "swipe across a stroke erases it")
        check(m.elements.contains { if case .stroke(let s, _) = $0 { return s[0].point.y == 50 }; return false },
              "neighbouring stroke untouched")

        // Writing inside a rectangle / ellipse does not erase it; touching the outline does.
        hit = m.erase(from: CGPoint(x: 250, y: 50), to: CGPoint(x: 255, y: 50), radius: 5, recordingUndo: false)
        check(!hit && m.elements.count == 3, "rectangle interior not erased")
        hit = m.erase(from: CGPoint(x: 450, y: 50), to: CGPoint(x: 452, y: 52), radius: 5, recordingUndo: false)
        check(!hit, "ellipse interior not erased")
        hit = m.erase(from: CGPoint(x: 297, y: 50), to: CGPoint(x: 297, y: 55), radius: 5, recordingUndo: true)
        check(hit && m.elements.count == 2, "rectangle outline erased")
        hit = m.erase(from: CGPoint(x: 450, y: 97), to: CGPoint(x: 450, y: 98), radius: 5, recordingUndo: true)
        check(hit && m.elements.count == 1, "ellipse outline erased")

        // Undo restores erased content step by step, then the appends.
        m.undo()
        check(m.elements.count == 2, "undo restores ellipse")
        m.undo()
        check(m.elements.count == 3, "undo restores rectangle")
        m.undo()
        check(m.elements.count == 4, "undo restores stroke")
        m.undo()
        check(m.elements.count == 3, "undo then removes last appended element")

        // One gesture erasing several elements is one undo step.
        let g = BoardModel()
        g.append(stroke([(0, 0), (0, 100)]))
        g.append(stroke([(20, 0), (20, 100)]))
        g.erase(from: CGPoint(x: -10, y: 50), to: CGPoint(x: 5, y: 50), radius: 3, recordingUndo: true)
        g.erase(from: CGPoint(x: 5, y: 50), to: CGPoint(x: 30, y: 50), radius: 3, recordingUndo: false)
        check(g.elements.isEmpty, "gesture erased both strokes")
        g.undo()
        check(g.elements.count == 2, "one undo restores whole eraser gesture")

        // Clear is undoable now.
        g.clear()
        g.undo()
        check(g.elements.count == 2, "clear is undoable")

        // Two-finger gesture helpers.
        typealias S = PalmRejector.ContactShape
        check(PalmRejector.isFingerShaped(S(size: 0.8, majorAxis: 9.2, minorAxis: 8.7)), "finger shape recognised")
        check(!PalmRejector.isFingerShaped(S(size: 0.52, majorAxis: 13.9, minorAxis: 7.1)), "palm heel is not a finger")
        check(!PalmRejector.isFingerShaped(S(size: 0.33, majorAxis: 6.6, minorAxis: 6.2)), "pen tip is not a finger")
        var r = PalmRejector()
        r.allowFinger = true
        let f = S(size: 0.8, majorAxis: 9.2, minorAxis: 8.7)
        let t1 = TouchSample(id: 1, pos: CGPoint(x: 0.4, y: 0.5), deviceSize: .zero, resting: false)
        _ = r.process([t1], shapes: [1: f], now: 0)
        check(r.canYieldToGesture(now: 0.1), "fresh finger stroke yields to a 2-finger gesture")
        check(!r.canYieldToGesture(now: 0.5), "established stroke does not yield")
        r.yieldToGesture()
        r.lockOut([1])
        let o = r.process([t1], shapes: [1: f], now: 0.6)
        check(o.pen == nil, "finger left after the gesture does not ink")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
