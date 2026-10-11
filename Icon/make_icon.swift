// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift Icon/make_icon.swift   (run from anywhere)
import AppKit

let size: CGFloat = 1024

func drawIcon(in ctx: CGContext) {
    let s = size
    // macOS icon grid: 824pt rounded square centred in 1024, with a soft drop shadow
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: indigo -> violet
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.36, green: 0.36, blue: 0.97, alpha: 1),
        CGColor(red: 0.62, green: 0.25, blue: 0.88, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s - 100), end: CGPoint(x: s, y: 100), options: [])
    ctx.restoreGState()

    // Paper sheet with a folded corner
    let sheet = CGRect(x: 262, y: 200, width: 500, height: 624)
    let fold: CGFloat = 120
    let sheetPath = CGMutablePath()
    sheetPath.move(to: CGPoint(x: sheet.minX, y: sheet.minY))
    sheetPath.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY))
    sheetPath.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
    sheetPath.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
    sheetPath.addLine(to: CGPoint(x: sheet.minX, y: sheet.maxY))
    sheetPath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(sheetPath)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Fold flap
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
    flap.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY - fold + 18))
    flap.addQuadCurve(to: CGPoint(x: sheet.maxX - fold + 18, y: sheet.maxY - fold),
                      control: CGPoint(x: sheet.maxX - fold, y: sheet.maxY - fold))
    flap.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
    flap.closeSubpath()
    ctx.addPath(flap)
    ctx.setFillColor(CGColor(red: 0.84, green: 0.84, blue: 0.92, alpha: 1))
    ctx.fillPath()

    // Markdown "#" heading and text lines
    let ink = CGColor(red: 0.78, green: 0.78, blue: 0.88, alpha: 1)
    let hash = NSAttributedString(string: "#", attributes: [
        .font: NSFont.systemFont(ofSize: 120, weight: .heavy),
        .foregroundColor: NSColor(red: 0.45, green: 0.38, blue: 0.95, alpha: 1),
    ])
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    hash.draw(at: CGPoint(x: sheet.minX + 52, y: sheet.maxY - 178))
    ctx.setFillColor(ink)
    for (i, w) in [CGFloat(180), 300, 250].enumerated() {
        let y = sheet.maxY - 140 - CGFloat(i) * 56
        let x = i == 0 ? sheet.minX + 150 : sheet.minX + 56
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: 22),
                           cornerWidth: 11, cornerHeight: 11, transform: nil))
    }
    ctx.fillPath()

    // Waveform bars, filled with the background gradient
    let heights: [CGFloat] = [70, 140, 230, 300, 200, 260, 150, 220, 110, 60]
    let barW: CGFloat = 26, gap: CGFloat = 13
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    let midY = sheet.minY + 190
    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let x = sheet.midX - total / 2 + CGFloat(i) * (barW + gap)
        bars.addPath(CGPath(roundedRect: CGRect(x: x, y: midY - h / 2, width: barW, height: h),
                            cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    }
    ctx.saveGState()
    ctx.addPath(bars)
    ctx.clip()
    ctx.drawLinearGradient(bg, start: CGPoint(x: sheet.minX, y: midY + 150),
                           end: CGPoint(x: sheet.maxX, y: midY - 150), options: [])
    ctx.restoreGState()
}

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let iconDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let resources = iconDir.deletingLastPathComponent().appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

for pt in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: pt).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try renderPNG(pixels: pt * 2).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
try renderPNG(pixels: 1024).write(to: iconDir.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote \(resources.appendingPathComponent("AppIcon.icns").path)")
