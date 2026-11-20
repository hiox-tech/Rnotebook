import AppKit
import ApplicationServices
import CoreGraphics
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "org.hiox.Rnotebook").first!
app.unhide(); app.activate(options: [.activateAllWindows])
let ax = AXUIElementCreateApplication(app.processIdentifier)
_ = AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.7))
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }), let number = window[kCGWindowNumber as String] as? NSNumber {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l", number.stringValue, "/tmp/rnotebook-window.png"]
    try process.run(); process.waitUntilExit(); print("captureExit:", process.terminationStatus)
} else { print("No screenshot-visible window; AX inspection remains available") }
