// Draws icon.png 1024×1024 for DynamicIsland: swift MakeIcon.swift icon.png
import AppKit

let side = 1024.0
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// A macOS-icon-shaped plate inset from the edges.
let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.46, green: 0.36, blue: 0.96, alpha: 1),
           ending: NSColor(srgbRed: 0.16, green: 0.10, blue: 0.42, alpha: 1))?.draw(in: plate, angle: -90)

// The island itself: a black capsule with artwork on the left and equalizer bars on the right.
let island = NSRect(x: 212, y: 437, width: 600, height: 150)
NSColor.black.setFill()
NSBezierPath(roundedRect: island, xRadius: 75, yRadius: 75).fill()

let cover = NSBezierPath(roundedRect: NSRect(x: island.minX + 30, y: island.minY + 30, width: 90, height: 90),
                         xRadius: 24, yRadius: 24)
NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.45, blue: 0.55, alpha: 1),
           ending: NSColor(srgbRed: 0.95, green: 0.2, blue: 0.4, alpha: 1))?.draw(in: cover, angle: -90)

NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1).setFill()
for (index, height) in [40.0, 84.0, 56.0, 96.0, 48.0].enumerated() {
    let bar = NSRect(x: island.maxX - 150 + Double(index) * 24, y: island.midY - height / 2, width: 14, height: height)
    NSBezierPath(roundedRect: bar, xRadius: 7, yRadius: 7).fill()
}
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output))
