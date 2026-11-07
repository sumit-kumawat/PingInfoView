import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let pixels = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not create icon bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()

let shape = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
shape.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.04, green: 0.22, blue: 0.55, alpha: 1),
    NSColor(calibratedRed: 0.12, green: 0.62, blue: 0.95, alpha: 1)
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), angle: 90)

NSColor.white.withAlphaComponent(0.95).setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: 250, y: 250, width: 524, height: 524))
ring.lineWidth = 28
ring.stroke()

let arc = NSBezierPath()
arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 180, startAngle: 210, endAngle: 20, clockwise: false)
arc.lineWidth = 22
arc.lineCapStyle = .round
arc.stroke()

let inner = NSBezierPath()
inner.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 90, startAngle: 200, endAngle: 40, clockwise: false)
inner.lineWidth = 18
inner.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.85).setStroke()
inner.stroke()

NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.55, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 690, y: 620, width: 78, height: 78)).fill()
NSColor(calibratedRed: 1, green: 0.38, blue: 0.38, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 250, y: 300, width: 64, height: 64)).fill()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Could not encode icon\n", stderr)
    exit(1)
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("PingInfoView.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let source = work.appendingPathComponent("source.png")
try png.write(to: source)

let sizes = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]
for (size, name) in sizes {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = ["-z", "\(size)", "\(size)", source.path, "--out", work.appendingPathComponent(name).path]
    try task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 { exit(task.terminationStatus) }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", work.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
