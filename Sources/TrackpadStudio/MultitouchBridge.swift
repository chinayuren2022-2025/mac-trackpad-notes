import AppKit
import CMultitouchShim
import Darwin

struct MTFingerSample {
    let id: Int
    let pos: CGPoint
    let size: Double
    let majorAxis: Double
    let minorAxis: Double
    let angle: Double
    var state: Int = 0
    var handID: Int = 0
    var density: Double = 0
    var pressure: Double = 0
}

/// Raw-frame observer for the touch recorder; sees every contact, unfiltered.
var multitouchRawTap: (([MTFingerSample], Double) -> Void)?
/// Raw-frame observer for the Freeform connector (same frames, all states).
var multitouchConnectorTap: (([MTFingerSample], Double) -> Void)?

private var activeMultitouchReader: MultitouchReader?

private let multitouchContactCallback: MTShimContactCallback = {
    _, touches, touchCount, _, _ in
    var samples: [MTFingerSample] = []
    var raw: [MTFingerSample] = []

    if touchCount > 0, let touches {
        samples.reserveCapacity(Int(touchCount))

        for index in 0..<Int(touchCount) {
            let touch = touches[index]
            let sample = MTFingerSample(
                    id: Int(touch.fingerID),
                    pos: CGPoint(
                        x: CGFloat(touch.normalized.pos.x),
                        y: CGFloat(touch.normalized.pos.y)
                    ),
                    size: Double(touch.size),
                    majorAxis: Double(touch.majorAxis),
                    minorAxis: Double(touch.minorAxis),
                    angle: Double(touch.angle),
                    state: Int(touch.state),
                    handID: Int(touch.handID),
                    density: Double(touch.density),
                    pressure: Double(touch.pressure)
                )
            raw.append(sample)
            guard touch.size > 0.05 else { continue }
            samples.append(sample)
        }
    }

    DispatchQueue.main.async {
        let now = ProcessInfo.processInfo.systemUptime
        multitouchRawTap?(raw, now)
        multitouchConnectorTap?(raw, now)
        activeMultitouchReader?.publish(samples)
    }
    return 0
}

final class MultitouchReader {
    static let shared = MultitouchReader()

    private(set) var isAvailable: Bool = false
    private(set) var fingers: [MTFingerSample] = []
    /// False until the first frame arrives: without Input Monitoring the
    /// device starts but never calls back.
    private(set) var hasDeliveredFrames = false
    var onFrame: (([MTFingerSample]) -> Void)?

    private let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private var libraryHandle: UnsafeMutableRawPointer?
    private var createDeviceFunction: MTShimCreateDefaultFn?
    private var registerCallbackFunction: MTShimRegisterContactFrameCallbackFn?
    private var startDeviceFunction: MTShimDeviceStartFn?
    private var stopDeviceFunction: MTShimDeviceStopFn?
    private var releaseDeviceFunction: MTShimDeviceReleaseFn?
    private var device: MTShimDeviceRef?
    private var started = false

    private init() {}

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.start() }
            return
        }
        guard !started else { return }

        isAvailable = false
        fingers = []

        guard loadAPI(),
              let createDeviceFunction,
              let registerCallbackFunction,
              let startDeviceFunction,
              let device = createDeviceFunction()
        else {
            return
        }

        self.device = device
        activeMultitouchReader = self
        registerCallbackFunction(device, multitouchContactCallback)
        started = true
        startDeviceFunction(device, 0)
        isAvailable = true
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.stop() }
            return
        }

        if activeMultitouchReader === self {
            activeMultitouchReader = nil
        }

        started = false
        isAvailable = false
        fingers = []

        guard let device else { return }
        stopDeviceFunction?(device)
        releaseDeviceFunction?(device)
        self.device = nil
    }

    fileprivate func publish(_ samples: [MTFingerSample]) {
        guard started else { return }
        hasDeliveredFrames = true
        fingers = samples
        onFrame?(samples)
    }

    private func loadAPI() -> Bool {
        if libraryHandle != nil {
            return createDeviceFunction != nil
                && registerCallbackFunction != nil
                && startDeviceFunction != nil
                && stopDeviceFunction != nil
                && releaseDeviceFunction != nil
        }

        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            return false
        }

        guard
            let create: MTShimCreateDefaultFn = symbol(
                named: "MTDeviceCreateDefault",
                in: handle
            ),
            let register: MTShimRegisterContactFrameCallbackFn = symbol(
                named: "MTRegisterContactFrameCallback",
                in: handle
            ),
            let start: MTShimDeviceStartFn = symbol(
                named: "MTDeviceStart",
                in: handle
            ),
            let stop: MTShimDeviceStopFn = symbol(
                named: "MTDeviceStop",
                in: handle
            ),
            let release: MTShimDeviceReleaseFn = symbol(
                named: "MTDeviceRelease",
                in: handle
            )
        else {
            dlclose(handle)
            return false
        }

        libraryHandle = handle
        createDeviceFunction = create
        registerCallbackFunction = register
        startDeviceFunction = start
        stopDeviceFunction = stop
        releaseDeviceFunction = release
        return true
    }

    private func symbol<T>(
        named name: String,
        in handle: UnsafeMutableRawPointer
    ) -> T? {
        guard let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
