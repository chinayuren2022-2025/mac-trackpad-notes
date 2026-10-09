import Foundation

/// Writes timed JSONL recordings of every touch frame, so palm-rejection
/// thresholds can be derived from this pen and this hand instead of guessed.
/// Files land in ~/Library/Application Support/TrackpadStudio-Handwriting/touchlog.
final class TouchRecorder {
    static let shared = TouchRecorder()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackpadStudio-Handwriting/touchlog", isDirectory: true)
    }

    private(set) var label: String?
    private(set) var endsAt: TimeInterval = 0
    private(set) var mtFrames = 0
    private(set) var nsFrames = 0
    private var handle: FileHandle?
    private var timer: Timer?
    var onFinish: ((URL, Int, Int) -> Void)?
    private var url: URL?

    var isRecording: Bool { handle != nil }

    func start(label: String, seconds: TimeInterval) {
        stop()
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(label)-\(stamp).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        self.url = url
        self.handle = handle
        self.label = label
        mtFrames = 0
        nsFrames = 0
        endsAt = ProcessInfo.processInfo.systemUptime + seconds
        write(["type": "start", "label": label, "seconds": seconds,
               "mtAvailable": MultitouchReader.shared.isAvailable])

        multitouchRawTap = { [weak self] fingers, now in
            self?.recordMT(fingers, now: now)
        }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.stop()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        guard let handle, let url else { return }
        write(["type": "end", "mtFrames": mtFrames, "nsFrames": nsFrames])
        try? handle.close()
        self.handle = nil
        self.url = nil
        label = nil
        timer?.invalidate()
        timer = nil
        multitouchRawTap = nil
        onFinish?(url, mtFrames, nsFrames)
    }

    func recordTouches(
        _ touches: [TouchSample],
        pen: Int?,
        rejected: [Int],
        sizes: [Int: Double]
    ) {
        guard handle != nil else { return }
        nsFrames += 1
        write([
            "type": "ns",
            "t": ProcessInfo.processInfo.systemUptime,
            "touches": touches.map { t -> [String: Any] in
                var d: [String: Any] = [
                    "id": t.id, "x": r(t.pos.x), "y": r(t.pos.y), "resting": t.resting,
                ]
                if let size = sizes[t.id] { d["size"] = r(size) }
                return d
            },
            "pen": pen ?? NSNull(),
            "rejected": rejected,
        ])
    }

    private func recordMT(_ fingers: [MTFingerSample], now: Double) {
        guard handle != nil else { return }
        mtFrames += 1
        write([
            "type": "mt",
            "t": now,
            "c": fingers.map {
                [
                    "fid": $0.id, "hid": $0.handID, "st": $0.state,
                    "x": r($0.pos.x), "y": r($0.pos.y),
                    "size": r($0.size), "maj": r($0.majorAxis), "min": r($0.minorAxis),
                    "ang": r($0.angle), "den": r($0.density), "p": r($0.pressure),
                ] as [String: Any]
            },
        ])
    }

    private func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private func r(_ v: CGFloat) -> Double { r(Double(v)) }

    private func write(_ object: [String: Any]) {
        guard let handle,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        handle.write(data)
    }
}
