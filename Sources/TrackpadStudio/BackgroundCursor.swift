import AppKit

/// The pointer while writing in the mini window over another app. The panel
/// does not activate this app (activating would pull the user out of a
/// full-screen space), and macOS applies a hidden cursor and a frozen pointer
/// only to the frontmost app. So: hide it with the window server's
/// "SetsCursorInBackground" connection property, and keep putting it back over
/// the panel so a press still lands there.
enum BackgroundCursor {
    private static var hidden = false
    /// Off for the --snapshot / --bench test runs: they must not take the
    /// user's pointer.
    static var isEnabled = true

    private static let canHideInBackground: Bool = {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connect = dlsym(handle, "_CGSDefaultConnection"),
              let set = dlsym(handle, "CGSSetConnectionProperty") else { return false }
        let cid = unsafeBitCast(connect, to: DefaultConnection.self)()
        return unsafeBitCast(set, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    /// A warp normally mutes the trackpad's own clicks for 0.25 s, which
    /// would swallow the press that starts a stroke in press-to-write mode.
    private static let allowClicksRightAfterWarp: Void = {
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
    }()

    static var isHidden: Bool { hidden }

    static func hide() {
        guard isEnabled, !hidden, canHideInBackground else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }

    /// Moves the pointer (without generating events) back to the middle of
    /// `window` once it has drifted from there.
    static func pin(to window: NSWindow) {
        guard isEnabled, let primary = NSScreen.screens.first else { return }
        _ = allowClicksRightAfterWarp
        let frame = window.frame
        let mouse = NSEvent.mouseLocation
        guard hypot(mouse.x - frame.midX, mouse.y - frame.midY) > 24 else { return }
        // Quartz display space: y down from the top of the primary screen.
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: primary.frame.maxY - frame.midY))
    }
}
