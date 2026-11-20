import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let evidence = root.appendingPathComponent(".local/validation/complex-notebook-2026-11-06")
let example = root.appendingPathComponent("Examples/ComplexNotebook/复杂验证.qmd")
let action = CommandLine.arguments.dropFirst().first ?? "snapshot"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "org.hiox.Rnotebook").first else { fatalError("Rnotebook not running") }
let ax = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ node: AXUIElement, _ key: String) -> CFTypeRef? { var value: CFTypeRef?; AXUIElementCopyAttributeValue(node, key as CFString, &value); return value }
func find(_ node: AXUIElement, depth: Int = 0, matching: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 28 else { return nil }; if matching(node) { return node }
    if attr(node, kAXRoleAttribute) as? String == kAXTextAreaRole { return nil }
    for child in attr(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let result = find(child, depth: depth + 1, matching: matching) { return result } }
    return nil
}
func windows() -> [AXUIElement] { attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
func documentWindow() -> AXUIElement? { windows().first { (attr($0, kAXTitleAttribute) as? String ?? "").contains("复杂验证") } }
func settle(_ seconds: Double = 0.5) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
func save(_ name: String, _ value: Any) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent(name), options: .atomic) }
func press(_ node: AXUIElement) throws { let result = AXUIElementPerformAction(node, kAXPressAction as CFString); guard result == .success else { throw NSError(domain:"AX",code:Int(result.rawValue)) } }
func snapshot() -> [[String:Any]] {
    windows().map { window in
        let editor = find(window, matching: { attr($0,kAXIdentifierAttribute) as? String == "record-native-editor" })
        let text = editor.flatMap { attr($0,kAXValueAttribute) as? String }
        return ["title":attr(window,kAXTitleAttribute) as? String ?? "", "source":text ?? "", "bytes":text?.utf8.count ?? -1, "hash":text.map { SHA256.hash(data:Data($0.utf8)).map { String(format:"%02x",$0) }.joined() } ?? ""]
    }
}
try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories:true)
if action == "finish" {
    for phase in ["run", "status", "toggle", "status", "capture", "after"] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        p.arguments = [#filePath, phase]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { print("Stopped at", phase); exit(p.terminationStatus) }
        if phase == "run" { settle(4) }
        if phase == "status" {
            let report = try JSONSerialization.jsonObject(with: Data(contentsOf: evidence.appendingPathComponent("ui-status.json"))) as! [String: Any]
            guard (report["strings"] as? [String] ?? []).contains(where: { $0.contains("已完成 12 个代码块") }) else {
                print("Expected 12 completed blocks; inspect actual output before continuing"); exit(5)
            }
        }
    }
} else if action == "snapshot" {
    let before=snapshot();try save("ui-before.json",before)
    print("Saved",before.count,"existing windows; no content replaced")
} else if action == "open" {
    let process = Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/open")
    process.arguments=["-a",app.bundleURL!.path,example.path];try process.run();process.waitUntilExit();settle(1)
    print("openExit",process.terminationStatus,"exampleWindow",documentWindow() != nil)
} else if action == "run" {
    guard let window=documentWindow(),let button=find(window,matching:{ attr($0,kAXDescriptionAttribute) as? String == "运行全部／停止" || attr($0,kAXHelpAttribute) as? String == "运行全部／停止" }) else { fatalError("Example run button not found") }
    try press(button);settle(0.2);print("Pressed actual Run All toolbar button once")
} else if action == "status" {
    guard let window=documentWindow() else { fatalError("Example window missing") }
    var strings:[String]=[]
    func walk(_ node:AXUIElement,_ depth:Int=0) {
        guard depth<25 else{return}
        if attr(node,kAXRoleAttribute) as? String == kAXTextAreaRole {return}
        for key in [kAXValueAttribute,kAXTitleAttribute,kAXDescriptionAttribute] {if let s=attr(node,key) as? String,!s.isEmpty {strings.append(s)}}
        for child in attr(node,kAXChildrenAttribute) as? [AXUIElement] ?? [] {walk(child,depth+1)}
    }
    walk(window);try save("ui-status.json",["pid":app.processIdentifier,"strings":strings])
    print(strings.filter{$0.contains("已完成") || $0.contains("R ") || $0.contains("COMPLEX") || $0.contains("错误") || $0.contains("失败")}.prefix(25).joined(separator:"\n"))
} else if action == "toggle" {
    guard let window=documentWindow(),let control=find(window,matching:{ attr($0,kAXRoleAttribute) as? String == kAXRadioGroupRole }) else { fatalError("View control missing") }
    var modes:[AXUIElement]=[]
    for child in attr(control,kAXChildrenAttribute) as? [AXUIElement] ?? [] {modes.append(child)}
    for index in [0,1,0,1] {guard modes.indices.contains(index) else {fatalError("Missing mode")};try press(modes[index]);settle(0.3)}
    print("Switched Code/Visual twice; no text edits")
} else if action == "capture" {
    guard let window=documentWindow() else {fatalError("Example missing")}
    app.activate(options:[.activateAllWindows]);_ = AXUIElementPerformAction(window,kAXRaiseAction as CFString);settle(0.5)
    var position=CGPoint.zero,size=CGSize.zero
    if let p=attr(window,kAXPositionAttribute){AXValueGetValue(p as! AXValue,.cgPoint,&position)}
    if let s=attr(window,kAXSizeAttribute){AXValueGetValue(s as! AXValue,.cgSize,&size)}
    let all=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
    let match=all.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier && ($0[kCGWindowName as String] as? String ?? "").contains("复杂验证") }
        ?? all.first {($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int)==0}
    if let id=match?[kCGWindowNumber as String] as? NSNumber {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","-l",id.stringValue,evidence.appendingPathComponent("complex-window.png").path];try p.run();p.waitUntilExit();print("captureExit",p.terminationStatus)
    }
} else if action == "after" {
    let after=snapshot();try save("ui-after.json",after)
    let original=try JSONSerialization.jsonObject(with:Data(contentsOf:evidence.appendingPathComponent("ui-before.json"))) as! [[String:Any]]
    var intact=true; var emptyClosed=0
    for item in original {
        if !after.contains(where:{$0["title"] as? String == item["title"] as? String && $0["hash"] as? String == item["hash"] as? String}) {
            if item["bytes"] as? Int == 0 { emptyClosed += 1 } else { intact=false }
        }
    }
    print("Original content preserved:",intact,"safely closed empty windows:",emptyClosed)
    try save("preservation.json",["originalContentPreserved":intact,"emptyWindowsClosedDuringGuardedRestart":emptyClosed])
}
