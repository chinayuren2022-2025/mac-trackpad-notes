import Foundation

/// Writes JSONL recordings of every touch frame, so palm-rejection
/// thresholds can be derived from this pen and this hand instead of guessed.
/// Files land in ~/Library/Application Support/TrackpadStudio-Handwriting/touchlog.
///
/// Two kinds: a timed recording started from the menu (one labelled task,
/// every frame), and the continuous log of everyday writing (frames only
/// while the board takes ink, plus stroke / undo / erase events as labels),
/// one gzipped file per writing session under touchlog/continuous.
final class TouchRecorder {
    static let shared = TouchRecorder()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackpadStudio-Handwriting/touchlog", isDirectory: true)
    }
    static var continuousDirectory: URL {
        directory.appendingPathComponent("continuous", isDirectory: true)
    }

    // MARK: Timed recording

    private(set) var label: String?
    private(set) var endsAt: TimeInterval = 0
    private(set) var mtFrames = 0
    private(set) var nsFrames = 0
    private var timed: LogFile?
    private var timer: Timer?
    var onFinish: ((URL, Int, Int) -> Void)?

    var isRecording: Bool { timed != nil }

    // MARK: Continuous log

    var isContinuous = UserDefaults.standard.bool(forKey: "continuousTouchLog") {
        didSet {
            UserDefaults.standard.set(isContinuous, forKey: "continuousTouchLog")
            if !isContinuous { closeSession() }
        }
    }
    /// True while the board takes ink; frames outside writing are not logged.
    var isWriting: () -> Bool = { false }
    /// Settings that change how frames were judged, written at session start.
    var context: () -> [String: Any] = { [:] }
    private var session: LogFile?
    private var sessionStart: TimeInterval = 0
    private var lastActivity: TimeInterval = 0
    /// A pause this long ends the session file; so does this much writing.
    private let idleGap: TimeInterval = 60
    private let maxSession: TimeInterval = 15 * 60
    /// Oldest sessions go once the folder grows past this.
    private let diskCap: Int64 = 2_000_000_000
    private let compressQueue = DispatchQueue(label: "touchlog.compress", qos: .utility)

    private init() {
        multitouchRawTap = { [weak self] fingers, now in
            self?.recordMT(fingers, now: now)
        }
        // Flush once a second, and close a session that has gone quiet.
        let flush = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(flush, forMode: .common)
        // A session left open by a crash is compressed like any other. Listed
        // now, before this run opens a session of its own.
        let leftovers = Self.continuousFiles().filter { $0.pathExtension == "jsonl" }
        compressQueue.async { leftovers.forEach(Self.gzip) }
    }

    func start(label: String, seconds: TimeInterval) {
        stop()
        let dir = Self.directory
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        guard let file = LogFile(url: dir.appendingPathComponent("\(label)-\(stamp).jsonl")) else { return }
        timed = file
        self.label = label
        mtFrames = 0
        nsFrames = 0
        endsAt = ProcessInfo.processInfo.systemUptime + seconds
        file.write(["type": "start", "label": label, "seconds": seconds,
                    "mtAvailable": MultitouchReader.shared.isAvailable])

        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.stop()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        guard let file = timed else { return }
        file.write(["type": "end", "mtFrames": mtFrames, "nsFrames": nsFrames])
        file.close()
        timed = nil
        label = nil
        timer?.invalidate()
        timer = nil
        onFinish?(file.url, mtFrames, nsFrames)
    }

    /// Ends the continuous session (app quitting, log switched off).
    func closeSession() {
        guard let file = session else { return }
        file.write(["type": "end", "t": ProcessInfo.processInfo.systemUptime, "frames": file.frames])
        file.close()
        session = nil
        let url = file.url
        compressQueue.async { [diskCap] in
            Self.gzip(url)
            Self.prune(cap: diskCap)
        }
    }

    func recordTouches(
        _ touches: [TouchSample],
        pen: Int?,
        rejected: [Int],
        sizes: [Int: Double]
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let files = targets(now: now, frame: !touches.isEmpty)
        guard !files.isEmpty else { return }
        if timed != nil { nsFrames += 1 }
        let record: [String: Any] = [
            "type": "ns",
            "t": now,
            "touches": touches.map { t -> [String: Any] in
                var d: [String: Any] = [
                    "id": t.id, "x": fine(t.pos.x), "y": fine(t.pos.y), "resting": t.resting,
                ]
                if let size = sizes[t.id] { d["size"] = r(size) }
                return d
            },
            "pen": pen ?? NSNull(),
            "rejected": rejected,
        ]
        files.forEach { $0.write(record) }
    }

    /// A labelling event for the continuous log: a stroke kept, a draft
    /// discarded, an undo, an erase. Written whether or not the board is in
    /// writing mode, since an undo often comes after switching to the pointer.
    func note(_ type: String, _ fields: [String: Any] = [:]) {
        guard isContinuous else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let file = session ?? (isWriting() ? openSession(now: now) : nil) else { return }
        var record = fields
        record["type"] = type
        record["t"] = now
        file.write(record)
    }

    private func recordMT(_ fingers: [MTFingerSample], now: Double) {
        let files = targets(now: now, frame: !fingers.isEmpty)
        guard !files.isEmpty else { return }
        if timed != nil { mtFrames += 1 }
        let record: [String: Any] = [
            "type": "mt",
            "t": now,
            "c": fingers.map {
                [
                    "fid": $0.id, "hid": $0.handID, "st": $0.state,
                    "x": fine($0.pos.x), "y": fine($0.pos.y),
                    "size": r($0.size), "maj": r($0.majorAxis), "min": r($0.minorAxis),
                    "ang": r($0.angle), "den": r($0.density), "p": r($0.pressure),
                ] as [String: Any]
            },
        ]
        files.forEach { $0.write(record) }
    }

    /// Files this frame goes to. An empty frame (all contacts lifted) does
    /// not open a session, but is kept in an open one as the lift marker.
    private func targets(now: TimeInterval, frame: Bool) -> [LogFile] {
        var files: [LogFile] = []
        if let timed { files.append(timed) }
        if isContinuous, isWriting() {
            if let session {
                files.append(session)
                if frame { lastActivity = now }
            } else if frame, let opened = openSession(now: now) {
                files.append(opened)
            }
        }
        return files
    }

    private func openSession(now: TimeInterval) -> LogFile? {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH-mm-ss"
        let date = Date()
        let url = Self.continuousDirectory
            .appendingPathComponent(day.string(from: date), isDirectory: true)
            .appendingPathComponent("\(time.string(from: date)).jsonl")
        guard let file = LogFile(url: url) else { return nil }
        session = file
        sessionStart = now
        lastActivity = now
        var start = context()
        start["type"] = "start"
        start["t"] = now
        start["date"] = ISO8601DateFormatter().string(from: date)
        start["mtAvailable"] = MultitouchReader.shared.isAvailable
        file.write(start)
        return file
    }

    private func tick() {
        timed?.flush()
        guard let session else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastActivity > idleGap || now - sessionStart > maxSession {
            closeSession()
        } else {
            session.flush()
        }
    }

    private func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private func r(_ v: CGFloat) -> Double { r(Double(v)) }
    /// Positions keep 0.01 mm: three decimals would quantise them to 0.12 mm.
    private func fine(_ v: CGFloat) -> Double { (Double(v) * 100_000).rounded() / 100_000 }

    // MARK: Files

    private static func gzip(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    /// Deletes the oldest continuous sessions until the folder fits the cap.
    private static func prune(cap: Int64) {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        var files = continuousFiles()
            .filter { $0.pathExtension == "gz" }
            .map { ($0, Int64((try? $0.resourceValues(forKeys: keys))?.fileSize ?? 0)) }
        var total = files.reduce(0) { $0 + $1.1 }
        // Paths are day/time, so name order is age order.
        files.sort { $0.0.path < $1.0.path }
        for (url, size) in files where total > cap {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    private static func continuousFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: continuousDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "jsonl" || $0.pathExtension == "gz"
        }
    }
}

/// One JSONL file, buffered so a 90 Hz frame stream costs a write a second.
private final class LogFile {
    let url: URL
    private(set) var frames = 0
    private let handle: FileHandle
    private var buffer = Data()

    init?(url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.handle = handle
    }

    func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        buffer.append(data)
        frames += 1
        if buffer.count > 256 * 1024 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() {
        flush()
        try? handle.close()
    }
}
