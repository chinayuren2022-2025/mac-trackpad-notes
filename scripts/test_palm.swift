import AppKit

// swiftc -parse-as-library scripts/test_palm.swift \
//   Sources/TrackpadStudio/{TrackpadCore,PalmRejection,PenAim,PressureGate}.swift -o /tmp/test_palm

@main
struct PalmChecks {
    static var failures = 0

    static func t(_ id: Int, _ x: CGFloat, _ y: CGFloat) -> TouchSample {
        TouchSample(id: id, pos: CGPoint(x: x, y: y), deviceSize: CGSize(width: 400, height: 250), resting: false)
    }

    static let penShape = PalmRejector.ContactShape(size: 0.33, majorAxis: 6.6, minorAxis: 6.2)
    static let palmShape = PalmRejector.ContactShape(size: 4.7, majorAxis: 34, minorAxis: 16)

    static func check(_ ok: Bool, _ name: String) {
        print((ok ? "PASS " : "FAIL ") + name)
        if !ok { failures += 1 }
    }

    static func main() {
        // 1. Pen writes, palm lands lower-right mid-stroke: pen keeps inking, palm ignored.
        do {
            var r = PalmRejector()
            _ = r.process([t(1, 0.4, 0.6)], shapes: nil, now: 0)
            _ = r.process([t(1, 0.45, 0.62)], shapes: nil, now: 0.05)
            let o = r.process([t(1, 0.5, 0.6), t(2, 0.7, 0.2)], shapes: nil, now: 0.1)
            check(o.pen?.id == 1 && o.rejected.map(\.id) == [2] && !o.previousPenEnded, "palm mid-stroke does not break stroke")
        }
        // 2. Palm rests first, then pen touches above-left: pen takes over, palm dot discarded.
        do {
            var r = PalmRejector()
            _ = r.process([t(2, 0.7, 0.2)], shapes: nil, now: 0)
            let o = r.process([t(2, 0.702, 0.2), t(1, 0.4, 0.6)], shapes: nil, now: 1)
            check(o.pen?.id == 1 && o.previousPenEnded && o.discardPrevious && o.rejected.map(\.id) == [2], "pen takes over from resting palm")
        }
        // 3. After pen lifts, the palm left on the pad never becomes the pen.
        do {
            var r = PalmRejector()
            _ = r.process([t(1, 0.4, 0.6)], shapes: nil, now: 0)
            _ = r.process([t(1, 0.5, 0.6), t(2, 0.7, 0.2)], shapes: nil, now: 0.1)
            let lift = r.process([t(2, 0.72, 0.21)], shapes: nil, now: 0.2)
            check(lift.pen == nil && lift.previousPenEnded && !lift.discardPrevious, "pen lift commits stroke, palm stays rejected")
            let next = r.process([t(2, 0.75, 0.22), t(3, 0.45, 0.6)], shapes: nil, now: 0.4)
            check(next.pen?.id == 3, "next pen contact is accepted while palm stays down")
        }
        // 4. A moving pen is never taken over by a newcomer placed higher.
        do {
            var r = PalmRejector()
            _ = r.process([t(1, 0.4, 0.4)], shapes: nil, now: 0)
            _ = r.process([t(1, 0.5, 0.45)], shapes: nil, now: 0.1)
            let o = r.process([t(1, 0.52, 0.45), t(2, 0.3, 0.9)], shapes: nil, now: 0.15)
            check(o.pen?.id == 1 && !o.previousPenEnded, "moving pen keeps the lock")
        }
        // 5. Long still contact lifted without moving is discarded; a quick tap (dot) is kept.
        do {
            var r = PalmRejector()
            _ = r.process([t(1, 0.4, 0.4)], shapes: nil, now: 0)
            let o = r.process([], shapes: nil, now: 1.0)
            check(o.previousPenEnded && o.discardPrevious, "long still blob discarded")
            _ = r.process([t(2, 0.4, 0.4)], shapes: nil, now: 2)
            let dot = r.process([], shapes: nil, now: 2.1)
            check(dot.previousPenEnded && !dot.discardPrevious, "quick dot kept")
        }
        // 6. Shape: palm-shaped contact is rejected even when alone; tip accepted below it.
        do {
            var r = PalmRejector()
            let o = r.process([t(2, 0.5, 0.5)], shapes: [2: palmShape], now: 0)
            check(o.pen == nil && o.rejected.map(\.id) == [2], "palm-shaped contact alone never inks")
            let o2 = r.process([t(2, 0.5, 0.5), t(1, 0.3, 0.1)], shapes: [2: palmShape, 1: penShape], now: 0.1)
            check(o2.pen?.id == 1, "pen-shaped tip accepted even below the palm")
        }
        // 7. Left-hand: pen sits above-right of the palm.
        do {
            var r = PalmRejector()
            r.hand = .left
            let o = r.process([t(1, 0.3, 0.3), t(2, 0.6, 0.35)], shapes: nil, now: 0)
            check(o.pen?.id == 2, "left hand prefers the right-hand contact")
        }
        // 8. Pen contact turning palm-shaped drops the stroke.
        do {
            var r = PalmRejector()
            _ = r.process([t(1, 0.4, 0.4)], shapes: [1: penShape], now: 0)
            let o = r.process([t(1, 0.4, 0.4)], shapes: [1: palmShape], now: 0.1)
            check(o.pen == nil && o.discardPrevious, "contact turning palm-shaped is dropped")
        }
        // 9. Shape not seen yet: pending, then accepted once it reads as a pen.
        do {
            var r = PalmRejector()
            let o = r.process([t(1, 0.4, 0.6)], shapes: [:], now: 0)
            check(o.pen == nil, "unclassified contact does not ink")
            let o2 = r.process([t(1, 0.4, 0.6)], shapes: [1: penShape], now: 0.01)
            check(o2.pen?.id == 1, "pending contact accepted once pen-shaped")
        }
        // 9b. A finger accepted in finger mode survives one borderline frame.
        do {
            var r = PalmRejector()
            r.allowFinger = true
            let finger = PalmRejector.ContactShape(size: 0.8, majorAxis: 9.2, minorAxis: 8.7)
            let wobble = PalmRejector.ContactShape(size: 0.95, majorAxis: 10.6, minorAxis: 7.5)
            _ = r.process([t(1, 0.4, 0.6)], shapes: [1: finger], now: 0)
            let o = r.process([t(1, 0.42, 0.6)], shapes: [1: wobble], now: 0.01)
            check(o.pen?.id == 1 && !o.previousPenEnded, "accepted finger survives a borderline frame")
        }
        // 10. Classifier on recorded shapes (pen / finger / palm heel / palm).
        do {
            typealias S = PalmRejector.ContactShape
            let pen = S(size: 0.33, majorAxis: 6.6, minorAxis: 6.2)
            let finger = S(size: 0.8, majorAxis: 9.2, minorAxis: 8.7)
            let heel = S(size: 0.52, majorAxis: 13.9, minorAxis: 7.1)
            let smallPalm = S(size: 0.19, majorAxis: 9.5, minorAxis: 4.6)
            let palm = S(size: 4.7, majorAxis: 34, minorAxis: 16)
            check(PalmRejector.classify(pen) == .pen, "classify: pen tip")
            check(PalmRejector.classify(finger) == .palm, "classify: finger rejected by default")
            check(PalmRejector.classify(finger, allowFinger: true) == .pen, "classify: finger allowed on opt-in")
            check(PalmRejector.classify(heel, allowFinger: true) == .palm, "classify: palm heel at edge")
            check(PalmRejector.classify(smallPalm, allowFinger: true) == .palm, "classify: small palm fragment")
            check(PalmRejector.classify(palm, allowFinger: true) == .palm, "classify: full palm")
        }

        // Pen landing prediction.
        let palms = [CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.9, y: 0.05)]
        check(PenAim.anchor(of: palms, hand: .right) == palms[0], "right hand: palm blob nearest the pen side")
        check(PenAim.anchor(of: palms, hand: .left) == palms[1], "left hand: mirrored")
        check(PenAim.anchor(of: [], hand: .right) == nil, "no palm, no prediction")
        var aim = PenAim(hand: .right)
        aim.learn(anchor: CGPoint(x: 0.6, y: 0.1), carried: nil, pen: CGPoint(x: 0.3, y: 0.5))
        let first = aim.predict(from: CGPoint(x: 0.6, y: 0.1))
        check(abs(first.x - 0.3) < 1e-9 && abs(first.y - 0.5) < 1e-9, "first stroke sets the offset")
        for _ in 0..<8 { aim.learn(anchor: CGPoint(x: 0.5, y: 0.1), carried: nil, pen: CGPoint(x: 0.2, y: 0.5)) }
        let before = aim.offset
        aim.learn(anchor: CGPoint(x: 0.9, y: 0.1), carried: nil, pen: CGPoint(x: 0.05, y: 0.95))
        check(aim.offset == before, "a far-off landing (hand moved) is ignored")
        check(aim.predict(from: CGPoint(x: 0.1, y: 0.9)) == CGPoint(x: 0, y: 1), "prediction stays on the pad")

        // Between strokes: the lift point travels with the hand.
        func touch(_ id: Int, _ x: CGFloat, _ y: CGFloat) -> TouchSample {
            TouchSample(id: id, pos: CGPoint(x: x, y: y), deviceSize: .zero, resting: true)
        }
        var tracker = PenAimTracker()
        var carriedAim = PenAim(hand: .right)
        _ = tracker.update(pen: touch(1, 0.40, 0.50), contacts: [touch(7, 0.70, 0.10)], anchor: CGPoint(x: 0.7, y: 0.1), now: 0, aim: &carriedAim)
        _ = tracker.update(pen: nil, contacts: [touch(7, 0.70, 0.10)], anchor: CGPoint(x: 0.7, y: 0.1), now: 0.05, aim: &carriedAim)
        let slid = [touch(7, 0.75, 0.12), touch(8, 0.9, 0.1)]   // palm slid right; 8 is new
        let carried = tracker.carried(contacts: slid, now: 0.2)
        check(carried.map { abs($0.x - 0.45) < 1e-9 && abs($0.y - 0.52) < 1e-9 } == true,
              "lift point moves with the contacts present at lift")
        check(tracker.carried(contacts: [touch(9, 0.7, 0.1)], now: 0.2) == nil, "no shared contact, no carried point")
        check(tracker.carried(contacts: slid, now: 0.05 + PenAimTracker.maxAir) == nil, "an old lift is forgotten")
        let blend = carriedAim.predict(anchor: CGPoint(x: 0.75, y: 0.12), carried: carried)!
        let palmGuess = carriedAim.predict(from: CGPoint(x: 0.75, y: 0.12))
        check(abs(blend.x - (0.7 * 0.45 + 0.3 * palmGuess.x)) < 1e-9, "both clues blend 70/30")
        // Landing 0.03 right of the carried point: the bias learns that step.
        let learned = tracker.update(pen: touch(2, 0.48, 0.52), contacts: slid, anchor: CGPoint(x: 0.75, y: 0.12), now: 0.2, aim: &carriedAim)
        check(learned && abs(carriedAim.bias.x - 0.03) < 1e-9 && carriedAim.carriedSamples == 1, "pen-down learns the bias")
        let old = Data(#"{"offset":[-0.3,0.35],"spread":0.08,"samples":12}"#.utf8)
        let decoded = try? JSONDecoder().decode(PenAim.self, from: old)
        check(decoded?.samples == 12 && decoded?.bias == .zero, "settings saved before the bias still load")

        // Press-to-write calibration.
        let light = (0..<150).map { 20 + Double($0 % 10) }          // 20…29
        let firm = (0..<150).map { 80 + Double($0 % 40) }           // 80…119
        if case let .success(gate) = PressureGate.calibrate(light: light, firm: firm) {
            check(gate.press > 29 && gate.press < 80, "press threshold sits between light and firm")
            check(gate.release > 28 && gate.release < gate.press, "release is below press (hysteresis)")
            check(!gate.isInking(pressure: 29, wasInking: false), "light touch does not ink")
            check(gate.isInking(pressure: 85, wasInking: false), "firm press inks")
            let between = (gate.release + gate.press) / 2
            check(gate.isInking(pressure: between, wasInking: true), "easing off a little keeps the stroke")
            check(!gate.isInking(pressure: between, wasInking: false), "same pressure does not start a stroke")
            check(gate.scaled(by: 0.9).press < gate.press, "[ makes writing lighter")
        } else {
            check(false, "calibration succeeds on separable data")
        }
        check(PressureGate.calibrate(light: [0, 0, 0], firm: [0, 0]) == .failure(.noPressureData), "all-zero pressure is detected")
        check(PressureGate.calibrate(light: light, firm: light.map { $0 + 2 }) == .failure(.notSeparable), "overlapping pressures are rejected")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
