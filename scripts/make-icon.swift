// Renders the app icon to Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (from the repository root)
import AppKit

/// Draws the icon on a 1024×1024 canvas, scaled to `pixels`.
func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // macOS icon grid: 824pt body centered on the 1024 canvas, continuous-corner rounded rect.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    cg.addPath(bodyPath)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Terracotta gradient, lighter at the top.
    cg.saveGState()
    cg.addPath(bodyPath)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.93, green: 0.60, blue: 0.45, alpha: 1).cgColor,
        NSColor(srgbRed: 0.76, green: 0.33, blue: 0.19, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()

    // Gauge: 270° arc open at the bottom, 70% filled, with a needle at the fill level.
    let center = CGPoint(x: 512, y: 488)
    let radius: CGFloat = 255
    let start = CGFloat.pi * 1.25            // 225°, bottom-left
    let sweep = CGFloat.pi * 1.5             // 270°, clockwise
    let fill: CGFloat = 0.7
    let valueAngle = start - sweep * fill

    cg.setLineCap(.round)
    cg.setLineWidth(72)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
    cg.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
    cg.strokePath()
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.addArc(center: center, radius: radius, startAngle: start, endAngle: valueAngle, clockwise: true)
    cg.strokePath()

    cg.setLineWidth(40)
    cg.move(to: center)
    cg.addLine(to: CGPoint(x: center.x + cos(valueAngle) * (radius - 95), y: center.y + sin(valueAngle) * (radius - 95)))
    cg.strokePath()
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillEllipse(in: CGRect(x: center.x - 48, y: center.y - 48, width: 96, height: 96))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try renderIcon(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try renderIcon(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? fileManager.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns")
