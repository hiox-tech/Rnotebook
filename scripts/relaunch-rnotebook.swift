import AppKit
import ApplicationServices
func attr(_ node: AXUIElement, _ key: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(node, key as CFString, &v); return v }
func find(_ node: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 25 else { return nil }
    if attr(node, kAXIdentifierAttribute) as? String == "record-native-editor" { return node }
    for child in attr(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let v = find(child, depth: depth + 1) { return v } }
    return nil
}
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "org.hiox.Rnotebook")
for app in apps {
    let node = AXUIElementCreateApplication(app.processIdentifier)
    guard let windows = attr(node, kAXWindowsAttribute) as? [AXUIElement], windows.count == 1,
        attr(windows[0], kAXTitleAttribute) as? String == "Untitled",
        let editor = find(windows[0]), attr(editor, kAXValueAttribute) as? String == "" else {
        print("Existing content or unknown window state: kept running, no restart"); exit(2)
    }
    guard app.terminate() else { print("Could not request graceful termination"); exit(3) }
    let until = Date(timeIntervalSinceNow: 8)
    while !app.isTerminated && Date() < until { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
    guard app.isTerminated else { print("App awaiting close review: kept running"); exit(4) }
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let configuration = CommandLine.arguments.dropFirst().first ?? "Debug"
let app = root.appendingPathComponent(".build/Rnotebook/Build/Products/\(configuration)/Rnotebook.app")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
p.arguments = ["-n", app.path]
try p.run(); p.waitUntilExit(); print("launchExit:",p.terminationStatus)
