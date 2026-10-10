import AppKit

// Camera pen tracking replayed from saved frames and the touch log:
// S=Sources/TrackpadStudio
// swiftc -O -parse-as-library scripts/replay_camerapen.swift $S/{PadCalibration,TipTracker}.swift -o /tmp/camreplay
// /tmp/camreplay <frames dir> <touch log .jsonl/.gz> "x,y x,y x,y x,y" [latency s] [--dump file] [--left]
// Frames are JPEGs named ...-<uptime>.jpg (scratch PenCam captures); the
// corners are the pad's bottom-left, top-left, top-right, bottom-right in
// frame pixels. Each frame in which the pen touches is located BEFORE the
// tracker learns from it, so the error is what the app would show.

@main
struct CameraReplay {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var dump: String?
        if let i = args.firstIndex(of: "--dump") { dump = args[i + 1]; args.removeSubrange(i...(i + 1)) }
        let leftHanded = args.contains("--left")
        args.removeAll { $0 == "--left" }
        let dir = args[0]
        let corners = args[2].split(separator: " ").map { pair -> CGPoint in
            let v = pair.split(separator: ",").map { Double($0)! }
            return CGPoint(x: v[0], y: v[1])
        }
        let latency = args.count > 3 ? Double(args[3])! : 0.05
        let touches = try loadTouches(args[1])

        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jpg") }
            .map { ($0, Double($0.split(separator: "-").last!.dropLast(4))!) }
            .sorted { $0.1 < $1.1 }
        var calibration: PadCalibration?
        var tracker = TipTracker()
        var cursor = HoverCursor()
        cursor.leftHanded = leftHanded
        var contactErrors: [Double] = [], hover = 0, hoverFound = 0
        var seconds = 0.0
        var lines: [String] = []
        // Hover sightings (time, pad) since the last touch, and how the
        // shown spot compared with the landing that followed.
        var air: [(t: Double, p: CGPoint)] = []
        var segments: [[(t: Double, p: CGPoint)]] = []
        var wasTouching = false
        let lags = [0.05, 0.1, 0.2, 0.3]
        var landing = Array(repeating: [Double](), count: lags.count)
        // The same after the pen was up over a second: aimed, then put down.
        var aimed = Array(repeating: [Double](), count: lags.count)
        var lastContact: Double?
        var steps: [Double] = []
        func mm(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x) * 124, Double(a.y - b.y) * 76) }
        for (name, t) in files where t <= (touches.last?.t ?? 0) {
            guard let (pixels, w, h) = luma(dir + "/" + name) else { continue }
            if calibration == nil { calibration = PadCalibration(corners: corners, imageSize: CGSize(width: w, height: h)) }
            guard var cal = calibration else { continue }
            let contact = touch(touches, at: t - latency)
            pixels.withUnsafeBufferPointer { buffer in
                let view = LumaView(base: buffer.baseAddress!, width: w, height: h, rowBytes: w)
                let start = Date()
                let seen = tracker.locate(view)
                seconds += Date().timeIntervalSince(start)
                if let contact {
                    if !wasTouching, !air.isEmpty {
                        for (i, lag) in lags.enumerated() {
                            // What the cursor showed `lag` before the landing.
                            if let shown = air.last(where: { $0.t <= t - lag }), t - lag - shown.t < 0.1 {
                                landing[i].append(mm(shown.p, contact))
                                if let lastContact, t - lastContact > 1 { aimed[i].append(mm(shown.p, contact)) }
                            }
                        }
                    }
                    segments.append(air)
                    air = []
                    wasTouching = true
                    lastContact = t
                    if let seen {
                        let p = cal.pad(at: seen.point)
                        contactErrors.append(hypot(Double(p.x - contact.x) * 124, Double(p.y - contact.y) * 76))
                        cal.learn(image: seen.point, pad: contact)
                    }
                    tracker.learn(view, tip: cal.image(at: contact), shaft: cal.shaft(at: contact, leftHanded: leftHanded))
                    _ = cursor.touch(contact, at: t - latency)
                    lines.append(String(format: "%.3f 1 %.1f %.1f", t, cal.image(at: contact).x, cal.image(at: contact).y))
                } else if tracker.hasLearned {
                    hover += 1
                    wasTouching = false
                    if let seen {
                        hoverFound += 1
                        let p = cursor.hover(cal.pad(at: seen.point), at: t - latency)
                        if let prev = air.last, t - prev.t < 0.1 { steps.append(mm(prev.p, p)) }
                        air.append((t, p))
                        lines.append(String(format: "%.3f 0 %.1f %.1f %.2f", t, seen.point.x, seen.point.y, seen.score))
                    }
                }
            }
            calibration = cal
        }
        func pct(_ v: [Double], _ p: Double) -> String {
            let s = v.sorted(); return String(format: "%.2f", s[min(s.count - 1, Int(Double(s.count) * p))])
        }
        print("frames \(files.count), tracking \(String(format: "%.1f", seconds * 1000 / Double(max(1, files.count)))) ms per frame")
        if !contactErrors.isEmpty {
            print("touching frames found before learning: \(contactErrors.count), error median \(pct(contactErrors, 0.5)) mm, 90% \(pct(contactErrors, 0.9)) mm")
        }
        print("in-air frames with a confident sighting: \(hoverFound)/\(hover)")
        for (i, lag) in lags.enumerated() where !landing[i].isEmpty {
            print(String(format: "cursor %.2f s before landing: %d landings, miss median %@ mm, 75%% %@, 90%% %@",
                         lag, landing[i].count, pct(landing[i], 0.5), pct(landing[i], 0.75), pct(landing[i], 0.9)))
        }
        for (i, lag) in lags.enumerated() where !aimed[i].isEmpty {
            print(String(format: "  after over 1 s up, %.2f s before landing: %d landings, miss median %@ mm",
                         lag, aimed[i].count, pct(aimed[i], 0.5)))
        }
        print(String(format: "learned reach along the pen: %.1f mm from %d landings", cursor.reach, cursor.reachSamples))
        // A frame far off the line through its neighbours: the cursor
        // jumped somewhere and came back.
        var spikes = 0, triples = 0
        for seg in segments + [air] where seg.count >= 3 {
            for i in 1..<(seg.count - 1) where seg[i + 1].t - seg[i - 1].t < 0.15 {
                let f = CGFloat((seg[i].t - seg[i - 1].t) / (seg[i + 1].t - seg[i - 1].t))
                let mid = CGPoint(x: seg[i - 1].p.x + (seg[i + 1].p.x - seg[i - 1].p.x) * f,
                                  y: seg[i - 1].p.y + (seg[i + 1].p.y - seg[i - 1].p.y) * f)
                triples += 1
                if mm(seg[i].p, mid) > 5 { spikes += 1 }
            }
        }
        print("hover spikes (> 5 mm off the neighbours' line): \(spikes)/\(triples)")
        if !steps.isEmpty {
            print("hover frame-to-frame step: median \(pct(steps, 0.5)) mm, 90% \(pct(steps, 0.9)), 99% \(pct(steps, 0.99)), jumps > 8 mm: \(steps.filter { $0 > 8 }.count)/\(steps.count)")
        }
        if let dump { try lines.joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8) }
    }

    /// Pen positions over time from the app's own pen choice.
    static func loadTouches(_ path: String) throws -> [(t: Double, p: CGPoint)] {
        let text: String
        if path.hasSuffix(".gz") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        } else {
            text = try String(contentsOfFile: path, encoding: .utf8)
        }
        var out: [(Double, CGPoint)] = []
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "ns", let t = obj["t"] as? Double, let pen = obj["pen"] as? Int,
                  let c = (obj["touches"] as? [[String: Any]])?.first(where: { $0["id"] as? Int == pen }) else { continue }
            out.append((t, CGPoint(x: c["x"] as! Double, y: c["y"] as! Double)))
        }
        return out
    }

    /// Where the pen touched at `s`, if it was touching then.
    static func touch(_ touches: [(t: Double, p: CGPoint)], at s: Double) -> CGPoint? {
        guard let k = touches.firstIndex(where: { $0.t >= s }), k > 0,
              touches[k].t - touches[k - 1].t < 0.03 else { return nil }
        let a = touches[k - 1], b = touches[k]
        let f = CGFloat((s - a.t) / (b.t - a.t))
        return CGPoint(x: a.p.x + (b.p.x - a.p.x) * f, y: a.p.y + (b.p.y - a.p.y) * f)
    }

    static func luma(_ path: String) -> ([UInt8], Int, Int)? {
        guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }
}
