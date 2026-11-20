import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Drives only an isolated acceptance bundle and its generated fixture documents.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let evidence = root.appendingPathComponent(".local/validation/feature-completion-2026-11-07/ui")
let bundleID = "org.hiox.Rnotebook.Acceptance"
let action = CommandLine.arguments.dropFirst().first ?? "inspect"
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
if action == "final-state" {
    let validation = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
    let normal = NSRunningApplication.runningApplications(withBundleIdentifier: "org.hiox.Rnotebook").map(\.processIdentifier)
    let report: [String: Any] = ["validationPIDs": validation, "normalPIDs": normal, "validationClosed": validation.isEmpty]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("closed.json"), options: .atomic)
    print("Validation closed:", validation.isEmpty, "normal running instances:", normal.count)
    exit(0)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { fail("Isolated acceptance app is not running") }
let ax = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?; AXUIElementCopyAttributeValue(node, key as CFString, &value); return value
}
func labeled(_ node: AXUIElement, _ title: String) -> Bool {
    [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].contains { attr(node,$0) as? String == title }
}
func find(_ node: AXUIElement, depth: Int = 0, matching: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 32 else { return nil }
    if matching(node) { return node }
    if attr(node, kAXRoleAttribute) as? String == kAXTextAreaRole { return nil }
    for child in attr(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = find(child, depth: depth + 1, matching: matching) { return found }
    }
    return nil
}
func settle(_ seconds: Double = 0.35) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
func windows() -> [AXUIElement] { attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
func window(_ title: String) throws -> AXUIElement {
    guard let window = windows().first(where: { (attr($0, kAXTitleAttribute) as? String ?? "").contains(title) }) else { throw NSError(domain: "UI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing window " + title]) }
    return window
}
func settingsWindow() throws -> AXUIElement {
    guard let value = windows().first(where: { attr($0, kAXIdentifierAttribute) as? String == "notebook-settings-window" }) else {
        throw NSError(domain: "UI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing settings window"])
    }
    return value
}
func settingsPane(_ window: AXUIElement, _ title: String) throws {
    guard let toolbar = find(window, matching: { attr($0, kAXRoleAttribute) as? String == kAXToolbarRole }),
          let item = find(toolbar, matching: { labeled($0, title) }) else { fail("Missing settings tab " + title) }
    try press(item)
}
func identified(_ node: AXUIElement, _ identifier: String) throws -> AXUIElement {
    guard let found = find(node, matching: { attr($0, kAXIdentifierAttribute) as? String == identifier }) else { throw NSError(domain: "UI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing control " + identifier]) }
    return found
}
func press(_ node: AXUIElement, allowDismissed: Bool = false) throws {
    let result = AXUIElementPerformAction(node, kAXPressAction as CFString)
    guard result == .success || allowDismissed && (result == .failure || result == .cannotComplete) else { throw NSError(domain: "AX", code: Int(result.rawValue)) }
    settle()
}
func raise(_ node: AXUIElement) {
    app.activate(options: [.activateAllWindows]); AXUIElementPerformAction(node, kAXRaiseAction as CFString); settle()
}
func menu(_ title: String, _ parent: String) throws {
    let bar = attr(ax, kAXMenuBarAttribute) as! AXUIElement
    guard let parent = find(bar, matching: { attr($0, kAXTitleAttribute) as? String == parent }) else { fail("Missing menu " + parent) }
    try press(parent)
    guard let item = find(parent, matching: { attr($0, kAXTitleAttribute) as? String == title }) else { fail("Missing menu item " + title) }
    try press(item)
}
func strings(_ node: AXUIElement) -> [String] {
    var result: [String] = []
    func walk(_ node: AXUIElement, _ depth: Int) {
        guard depth < 32 else { return }
        if attr(node, kAXRoleAttribute) as? String == kAXTextAreaRole { return }
        for key in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let s = attr(node, key) as? String, !s.isEmpty { result.append(s) }
        }
        for child in attr(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(node, 0); return result
}
func capture(_ node: AXUIElement, _ name: String) throws {
    raise(node)
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let title = attr(node, kAXTitleAttribute) as? String ?? ""
    var position = CGPoint.zero, size = CGSize.zero
    if let value = attr(node,kAXPositionAttribute) { AXValueGetValue(value as! AXValue,.cgPoint,&position) }
    if let value = attr(node,kAXSizeAttribute) { AXValueGetValue(value as! AXValue,.cgSize,&size) }
    let match = list.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier && ($0[kCGWindowName as String] as? String ?? "") == title }
        ?? list.first { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Double] else { return false }
            return abs((bounds["X"] ?? -99999)-position.x)<2 && abs((bounds["Y"] ?? -99999)-position.y)<2 &&
                abs((bounds["Width"] ?? -99999)-size.width)<2 && abs((bounds["Height"] ?? -99999)-size.height)<2
        }
    guard let id = match?[kCGWindowNumber as String] as? NSNumber else { fail("No visible capture window") }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-l", id.stringValue, evidence.appendingPathComponent(name + ".png").path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("Screenshot unavailable") }
}
func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!; event.flags = flags; event.post(tap: .cghidEventTap) }
    settle()
}
func save(_ name: String, _ data: Any) throws {
    try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent(name + ".json"), options: .atomic)
}
func choose(_ node: AXUIElement, _ identifier: String, _ title: String) throws {
    let popup = try identified(node, identifier); try press(popup)
    let predicate: (AXUIElement) -> Bool = { attr($0,kAXRoleAttribute) as? String == kAXMenuItemRole && attr($0,kAXTitleAttribute) as? String == title }
    guard let item = find(popup, matching: predicate) ?? find(ax, matching: predicate) else { fail("Missing popup choice " + title) }
    try press(item)
}
func settingsSize(_ window: AXUIElement, _ identifier: String, _ value: String) throws {
    let field = try identified(window, identifier)
    guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString) == .success else { fail("Cannot enter settings size") }
    _ = AXUIElementPerformAction(field, "AXConfirm" as CFString)
    settle()
}
func mode(_ node: AXUIElement, _ title: String) throws {
    guard let button = find(node, matching: { element in
        let role = attr(element,kAXRoleAttribute) as? String ?? ""
        return (role == kAXRadioButtonRole || role == kAXButtonRole) &&
            (attr(element,kAXTitleAttribute) as? String == title || attr(element,kAXDescriptionAttribute) as? String == title)
    }) else { fail("Missing mode " + title) }
    try press(button)
}
guard AXIsProcessTrusted() else { fail("Accessibility permission required for UI acceptance") }
if action == "inspect" {
    try save("inspection", ["pid": app.processIdentifier, "windows": windows().map { strings($0) }, "trusted": AXIsProcessTrusted()])
    print("Acceptance windows:", windows().map { attr($0, kAXTitleAttribute) as? String ?? "" })
} else if action == "layout" {
    let a = try window("Acceptance-A")
    var report: [[String: Any]] = []
    for (name, width, height) in [("light-small",960.0,640.0),("light-medium",1160,760),("light-wide",1440,880)] {
        var size = CGSize(width: width, height: height)
        let value = AXValueCreate(.cgSize, &size)!
        let result = AXUIElementSetAttributeValue(a, kAXSizeAttribute as CFString, value)
        settle(); try capture(a, name)
        report.append(["name": name, "resizeResult": result.rawValue, "strings": strings(a)])
    }
    if let control = find(a, matching: { attr($0,kAXRoleAttribute) as? String == kAXRadioGroupRole }),
       let code = (attr(control,kAXChildrenAttribute) as? [AXUIElement])?.first {
        try press(code); try capture(a, "code-top")
        let editor = try identified(a, "record-native-editor")
        AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        key(125, flags: .maskCommand); try capture(a, "code-end")
        if let visual = (attr(control,kAXChildrenAttribute) as? [AXUIElement])?.last { try press(visual) }
    }
    try save("layout", report)
    print("Captured three sizes and Code top/end")
} else if action == "run" {
    var report: [[String: Any]] = []
    for title in ["Acceptance-A", "Acceptance-B"] {
        let doc = try window(title); raise(doc)
        try menu("运行全部代码块", "Notebook")
        let deadline = Date(timeIntervalSinceNow: 15)
        while !strings(doc).contains(where: { $0.contains("已完成 1 个代码块") }), Date() < deadline { settle(0.2) }
        let values = strings(doc)
        guard values.contains(where: { $0.contains("已完成 1 个代码块") }) else { fail("Actual Run All failed " + title) }
        report.append(["document": title, "strings": values])
    }
    try save("run", report); print("Both active documents completed their own one-block run")
} else if action == "export" {
    let a = try window("Acceptance-A"); raise(a)
    try menu("Quarto 渲染导出…", "Notebook")
    let sheet = try identified(a, "quarto-export-sheet")
    try capture(a, "export-output")
    let source = try identified(sheet, "quarto-parameter-source")
    if let custom = find(source, matching: { labeled($0, "自定义") }) {
        try press(custom); try capture(a, "export-custom")
    }
    try save("export-controls", strings(a))
    if let close = find(sheet, matching: { attr($0,kAXTitleAttribute) as? String == "关闭" }) { try press(close) }
    print("Export format/source/custom/output flow captured")
} else if action == "settings" {
    try menu("设置…", "Rnotebook")
    let settings = try settingsWindow()
    for pane in ["通用", "编辑器", "环境"] {
        try settingsPane(settings, pane)
        try capture(settings, "settings-" + pane)
        try save("settings-controls-" + pane, strings(settings))
    }
    print("Settings captured")
} else if action == "appearance" {
    let a = try window("Acceptance-A"); raise(a)
    try menu("设置…", "Rnotebook")
    let settings = try settingsWindow()
    try settingsPane(settings, "通用")
    try mode(settings, "深色")
    try settingsPane(settings, "编辑器")
    try settingsSize(settings, "source-editor-size", "24")
    try settingsSize(settings, "visual-body-size", "24")
    if let close = attr(settings,kAXCloseButtonAttribute) { try press(close as! AXUIElement) }
    raise(a); try mode(a, "Code"); try capture(a, "dark-code-large-font")
    try mode(a, "Visual"); try capture(a, "dark-visual-large-font")
    let visualTools = find(a, matching: { attr($0,kAXIdentifierAttribute) as? String == "record-editing-toolbar" }) != nil
    try save("appearance", ["visualToolsVisible": visualTools, "strings": strings(a)])
    guard visualTools else { fail("Visual toolbar did not appear") }
    print("Dark appearance and larger fonts applied to Code and Visual")
} else if action == "edit" {
    let a = try window("Acceptance-A"); raise(a); try mode(a, "Code")
    let editor = try identified(a,"record-native-editor")
    let before = attr(editor,kAXValueAttribute) as! String
    let scroll = try identified(a,"record-notebook")
    var position=CGPoint.zero
    if let value=attr(scroll,kAXPositionAttribute) { AXValueGetValue(value as! AXValue,.cgPoint,&position) }
    for kind in [CGEventType.leftMouseDown,.leftMouseUp] {
        CGEvent(mouseEventSource:nil,mouseType:kind,mouseCursorPosition:CGPoint(x:position.x+110,y:position.y+180),mouseButton:.left)?.post(tap:.cghidEventTap)
    }
    settle()
    key(125,flags:.maskCommand)
    let marker = "\nEDIT_MARKER_中文"
    let clipboard=NSPasteboard.general
    var previous:[[NSPasteboard.PasteboardType:Data]]=[]
    for item in clipboard.pasteboardItems ?? [] {
        var record:[NSPasteboard.PasteboardType:Data]=[:]
        for type in item.types {
            guard let data=item.data(forType:type) else { fail("Clipboard cannot be fully preserved; leaving it unchanged") }
            record[type]=data
        }
        previous.append(record)
    }
    defer {
        clipboard.clearContents()
        let restored=previous.map { record in let item=NSPasteboardItem(); for (type,data) in record {item.setData(data,forType:type)}; return item }
        clipboard.writeObjects(restored)
    }
    clipboard.clearContents();clipboard.setString(marker,forType:.string)
    try menu("粘贴","编辑")
    let edited = attr(editor,kAXValueAttribute) as! String
    guard edited.contains("EDIT_MARKER_中文") else { throw NSError(domain:"UI",code:5,userInfo:[NSLocalizedDescriptionKey:"Paste failed"]) }
    key(6,flags:.maskCommand)
    guard attr(editor,kAXValueAttribute) as? String == before else { throw NSError(domain:"UI",code:6,userInfo:[NSLocalizedDescriptionKey:"Undo did not restore exact source"]) }
    key(6,flags:[.maskCommand,.maskShift])
    guard attr(editor,kAXValueAttribute) as? String == edited else { throw NSError(domain:"UI",code:7,userInfo:[NSLocalizedDescriptionKey:"Redo did not restore edit"]) }
    key(6,flags:.maskCommand); key(1,flags:.maskCommand)
    try save("editing",["nativePaste":true,"keyboardUndoExact":true,"keyboardRedoExact":true,"restoredOriginal":attr(editor,kAXValueAttribute) as? String == before])
    print("Actual paste, keyboard undo/redo and save passed; clipboard restored")
} else if action == "recovery" || action == "recovery-check" {
    if action == "recovery" {
        let recovery = try window("恢复未保存文档")
        try capture(recovery,"recovery-choice")
        guard let restore = find(recovery,matching:{ attr($0,kAXRoleAttribute) as? String == kAXButtonRole && labeled($0,"恢复所选") }) else { fail("Restore button missing") }
        try press(restore,allowDismissed:true)
    }
    let restored = try window("恢复的 Acceptance-A")
    let editor = try identified(restored,"record-native-editor")
    guard (attr(editor,kAXValueAttribute) as? String ?? "").contains("RECOVERY_UI_OK") else { fail("Recovery did not restore expected source") }
    guard strings(restored).contains("R 未启动") else { fail("Recovery must not execute R") }
    try capture(restored,"recovery-restored")
    try save("recovery",["sourceRestored":true,"rNotStarted":true])
    if let close = attr(restored,kAXCloseButtonAttribute) { try press(close as! AXUIElement,allowDismissed:true) }
    if let discard = find(ax,matching:{ node in attr(node,kAXRoleAttribute) as? String == kAXButtonRole && ["不存储","不保存","Don't Save","Delete","删除"].contains { labeled(node,$0) } }) { try press(discard,allowDismissed:true) }
    print("Actual recovery opened an unsaved copy without R execution")
} else if action == "dismiss-recovered" {
    let restored = try window("恢复的 Acceptance-A")
    guard (attr(try identified(restored,"record-native-editor"),kAXValueAttribute) as? String ?? "").contains("RECOVERY_UI_OK") else { fail("Unexpected source; leaving document open") }
    guard let discard = find(ax,matching:{ node in attr(node,kAXRoleAttribute) as? String == kAXButtonRole && ["不存储","不保存","Don't Save","Delete","删除"].contains { labeled(node,$0) } }) else { fail("Test-copy discard confirmation missing") }
    try press(discard,allowDismissed:true)
    guard !windows().contains(where:{(attr($0,kAXTitleAttribute) as? String ?? "").contains("恢复的 Acceptance-A")}) else { fail("Restored test copy still open") }
    print("Discarded only the restored test copy through native close review")
} else if action == "close" {
    // Only this isolated bundle owns these generated fixtures.
    app.terminate(); settle(1)
    print("Acceptance app terminated:", app.isTerminated)
}
