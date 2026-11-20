import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "org.hiox.Rnotebook")
guard let app = apps.first else { fatalError("Rnotebook is not running") }
let ax = AXUIElementCreateApplication(app.processIdentifier)
func value(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?; AXUIElementCopyAttributeValue(node, key as CFString, &result); return result
}
func find(_ node: AXUIElement, depth: Int = 0, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 25 else { return nil }
    if predicate(node) { return node }
    if value(node, kAXRoleAttribute) as? String == kAXTextAreaRole { return nil }
    for child in value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let result = find(child, depth: depth + 1, predicate: predicate) { return result }
    }
    return nil
}
let windows = value(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
var report: [String: Any] = ["pid": app.processIdentifier, "bundle": app.bundleURL?.path ?? "", "active": app.isActive, "windowCount": windows.count, "accessibilityTrusted": AXIsProcessTrusted()]
if let window = windows.first {
    report["title"] = value(window, kAXTitleAttribute) as? String ?? ""
    report["editorFound"] = find(window, predicate: { value($0, kAXIdentifierAttribute) as? String == "record-native-editor" }) != nil
    report["inspectorFound"] = find(window, predicate: { value($0, kAXIdentifierAttribute) as? String == "record-status-panel" }) != nil
    report["toolbarFound"] = find(window, predicate: { value($0, kAXRoleAttribute) as? String == kAXToolbarRole }) != nil
    report["minimized"] = value(window, kAXMinimizedAttribute) as? Bool ?? false
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
if let output = CommandLine.arguments.dropFirst().first { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
