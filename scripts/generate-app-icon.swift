import AppKit
import Foundation

// Reproducible vector drawing; no external assets or image services.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent(".local/Rnotebook.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let size = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    let outer = NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 196, yRadius: 196)
    NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.43, blue: 0.84, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.26, blue: 0.61, alpha: 1))!.draw(in: outer, angle: -90)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 234, y: 180, width: 578, height: 670), xRadius: 42, yRadius: 42).fill()
    NSColor(calibratedRed: 0.65, green: 0.79, blue: 0.95, alpha: 1).setStroke()
    for y in stride(from: 250, through: 750, by: 100) {
        let line = NSBezierPath(); line.lineWidth = 12
        line.move(to: NSPoint(x: 292, y: y)); line.line(to: NSPoint(x: 752, y: y)); line.stroke()
    }
    NSColor(calibratedRed: 0.18, green: 0.41, blue: 0.73, alpha: 1).setStroke()
    let spine = NSBezierPath(); spine.lineWidth = 22
    spine.move(to: NSPoint(x: 300, y: 185)); spine.line(to: NSPoint(x: 300, y: 845)); spine.stroke()
    let r = "R" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 420, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.62, alpha: 1)]
    r.draw(at: NSPoint(x: 368, y: 278), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let output = root.appendingPathComponent("DesktopApp/Resources/Rnotebook.icns")
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print(output.path)
