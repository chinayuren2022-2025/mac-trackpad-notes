import AVFoundation
import AppKit
import CoreImage

/// Shows where the hovering pen tip is, seen by a camera looking down at the
/// trackpad (an iPhone's Desk View camera through Continuity). The pad
/// cannot sense a tip in the air; the camera can. Every frame in which the
/// pen touches teaches the tracker what the tip looks like and refines
/// where the pad sits in the picture (`PadCalibration`), so the hover
/// position comes out in pad coordinates like a touch.
///
/// Frames are handled on the camera's own queue; callbacks arrive on main.
final class CameraPen: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraPen()

    struct Tip {
        /// Normalized pad position (0…1, origin bottom-left).
        let pad: CGPoint
        let score: Float
        let time: TimeInterval
    }

    /// A camera frame for the alignment window, with the tracker's view of it.
    struct Preview {
        let image: CGImage
        /// Tip seen in this frame, camera pixels.
        let tip: CGPoint?
        /// Where the touching pen is, by the calibration, camera pixels.
        let touch: CGPoint?
    }

    /// Posted on main whenever `tip` changes.
    static let tipChanged = Notification.Name("CameraPen.tipChanged")
    /// Hovering tip, or nil when it is lost or the pen touches; main only.
    private(set) var tip: Tip?
    /// Frames while the alignment window is open; on main.
    var onPreview: ((Preview) -> Void)?
    /// Camera started, stopped or failed; on main.
    var onState: ((String) -> Void)?

    /// Measured: the picture lags the touch report by about this much.
    static let latency: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "camera-pen")
    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var tracker = TipTracker()
    private var _calibration: PadCalibration?
    private var _previewing = false
    private var frameCount = 0
    private var learnedSinceSave = 0
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Pen position reports from the pad (nil = pen up), oldest first.
    private var contacts: [(time: TimeInterval, pad: CGPoint?)] = []
    private var cursor = HoverCursor()

    private(set) var isRunning = false
    private(set) var status = "未开启"

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.calibrationKey) {
            _calibration = try? JSONDecoder().decode(PadCalibration.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: Self.cursorKey),
           let saved = try? JSONDecoder().decode(HoverCursor.self, from: data) {
            cursor = saved
        }
    }

    // MARK: Settings

    static let calibrationKey = "cameraPen.calibration"
    static let deviceKey = "cameraPen.device"
    static let cursorKey = "cameraPen.cursor"

    var calibration: PadCalibration? {
        lock.lock(); defer { lock.unlock() }
        return _calibration
    }

    /// New corners from the alignment window (camera pixels, BL TL TR BR).
    func setCorners(_ corners: [CGPoint], imageSize: CGSize) {
        lock.lock()
        if var cal = _calibration, cal.imageSize == imageSize {
            cal.setCorners(corners)
            _calibration = cal
        } else {
            _calibration = PadCalibration(corners: corners, imageSize: imageSize)
        }
        let saved = _calibration
        lock.unlock()
        queue.async { [weak self] in
            // The landing offset depends on where the phone is.
            self?.tracker.reset()
            self?.cursor = HoverCursor()
        }
        save(saved)
    }

    var previewing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _previewing }
        set { lock.lock(); _previewing = newValue; lock.unlock() }
    }

    static func cameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.continuityCamera, .deskViewCamera, .external]
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    /// The chosen camera, else a Desk View camera, else any phone camera.
    static func preferredCamera() -> AVCaptureDevice? {
        let all = cameras()
        if let id = UserDefaults.standard.string(forKey: deviceKey), let chosen = all.first(where: { $0.uniqueID == id }) {
            return chosen
        }
        return all.first { $0.localizedName.contains("Desk View") }
            ?? all.first { $0.deviceType != .builtInWideAngleCamera }
            ?? all.first
    }

    // MARK: Running

    func start(device: AVCaptureDevice? = nil) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.start(device: device) } else { self.report("未获得摄像头权限") }
                }
            }
            return
        default:
            report("未获得摄像头权限：系统设置 → 隐私与安全性 → 摄像头")
            return
        }
        guard let device = device ?? Self.preferredCamera() else { report("没有找到摄像头（iPhone 靠近并解锁）"); return }
        UserDefaults.standard.set(device.uniqueID, forKey: Self.deviceKey)
        stop()
        queue.async { [weak self] in
            guard let self else { return }
            let session = AVCaptureSession()
            session.beginConfiguration()
            guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                DispatchQueue.main.async { self.report("无法打开 \(device.localizedName)") }
                return
            }
            session.addInput(input)
            // The most pixels: the tip is small in a wide view.
            if let format = device.formats.max(by: { Self.pixels($0) < Self.pixels($1) }),
               (try? device.lockForConfiguration()) != nil {
                device.activeFormat = format
                device.unlockForConfiguration()
            }
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.queue)
            guard session.canAddOutput(output) else {
                DispatchQueue.main.async { self.report("摄像头输出不可用") }
                return
            }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
            self.session = session
            self.tracker.reset()
            DispatchQueue.main.async {
                self.isRunning = true
                self.report("正在使用 \(device.localizedName)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            session.stopRunning()
            self.session = nil
            self.save(self.calibration)
            DispatchQueue.main.async {
                self.isRunning = false
                self.setTip(nil)
                self.report("已关闭")
            }
        }
    }

    /// The pad's pen, every touch frame (nil while the pen is up).
    func noteContact(_ pad: CGPoint?, at time: TimeInterval) {
        guard isRunning else { return }
        lock.lock()
        if pad != nil || contacts.last?.pad != nil { contacts.append((time, pad)) }
        if contacts.count > 400 { contacts.removeFirst(contacts.count - 300) }
        lock.unlock()
    }

    private func setTip(_ tip: Tip?) {
        guard tip != nil || self.tip != nil else { return }
        self.tip = tip
        NotificationCenter.default.post(name: Self.tipChanged, object: self)
    }

    private func report(_ text: String) {
        status = text
        onState?(text)
    }

    private static func pixels(_ format: AVCaptureDevice.Format) -> Int32 {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return d.width * d.height
    }

    private func save(_ calibration: PadCalibration?) {
        guard let calibration, let data = try? JSONEncoder().encode(calibration) else { return }
        UserDefaults.standard.set(data, forKey: Self.calibrationKey)
        if let data = try? JSONEncoder().encode(cursor) { UserDefaults.standard.set(data, forKey: Self.cursorKey) }
    }

    // MARK: Frames

    /// Where the pen touched at `time`, if it was touching.
    private func contact(at time: TimeInterval) -> CGPoint? {
        lock.lock(); defer { lock.unlock() }
        guard let k = contacts.firstIndex(where: { $0.time >= time }), k > 0,
              let a = contacts[k - 1].pad, let b = contacts[k].pad,
              contacts[k].time - contacts[k - 1].time < 0.05 else { return nil }
        let f = CGFloat((time - contacts[k - 1].time) / (contacts[k].time - contacts[k - 1].time))
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = ProcessInfo.processInfo.systemUptime - Self.latency
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCount += 1
        let touch = contact(at: time)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return
        }
        let view = LumaView(base: base.assumingMemoryBound(to: UInt8.self), width: width, height: height,
                            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        let size = CGSize(width: width, height: height)

        lock.lock()
        var calibration = _calibration
        lock.unlock()
        if let cal = calibration, cal.imageSize != size {
            // Another camera or format: keep the corners' place in the picture.
            let sx = size.width / cal.imageSize.width, sy = size.height / cal.imageSize.height
            calibration = PadCalibration(corners: cal.corners.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }, imageSize: size)
        }

        var seen: (point: CGPoint, score: Float)?
        var touchPixel: CGPoint?
        let leftHanded = UserDefaults.standard.string(forKey: "palmHand") == PalmRejector.Hand.left.rawValue
        cursor.leftHanded = leftHanded
        if var cal = calibration {
            seen = tracker.locate(view)
            if let touch {
                if let seen { cal.learn(image: seen.point, pad: touch) }
                touchPixel = cal.image(at: touch)
                tracker.learn(view, tip: touchPixel!, shaft: cal.shaft(at: touch, leftHanded: leftHanded))
                _ = cursor.touch(touch, at: time)
                learnedSinceSave += 1
            }
            calibration = cal
            lock.lock()
            _calibration = cal
            lock.unlock()
            if learnedSinceSave >= 120 {
                learnedSinceSave = 0
                save(cal)
            }
        }
        let wantsPreview = previewing && frameCount % 3 == 0
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

        let tip: Tip? = touch == nil ? seen.flatMap { s in
            calibration.map { Tip(pad: cursor.hover($0.pad(at: s.point), at: time), score: s.score, time: time) }
        } : nil
        var preview: Preview?
        if wantsPreview, let image = ciContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(origin: .zero, size: size)) {
            preview = Preview(image: image, tip: seen?.point, touch: touchPixel)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setTip(tip)
            if let preview { self.onPreview?(preview) }
        }
    }
}
