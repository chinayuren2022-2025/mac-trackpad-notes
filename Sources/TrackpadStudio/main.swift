import AppKit

let application = NSApplication.shared
let appDelegate = AppDelegate()

application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.activate(ignoringOtherApps: true)
application.run()
