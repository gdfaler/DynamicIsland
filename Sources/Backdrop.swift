import AppKit

/// The artwork blurred beyond recognition — only its colors and their arrangement are left. The visualizer's bars
/// are cut out of it.
enum BlurredArtwork {
    /// The cover is averaged down to a handful of pixels (what's left is only a coarse arrangement of its colors),
    /// recolored into harmonious tones and then smoothly stretched back up, so the transitions between the colors
    /// are soft gradients rather than edges.
    static func make(from image: NSImage) -> NSImage? {
        // Six columns and two rows: the bars are tall and narrow, so the cover's vertical detail would only show as
        // random stripes; the foot-to-tip gradient comes from the recoloring instead.
        let columns = 6, rows = 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: columns, height: rows)
        let graphics = NSGraphicsContext(cgContext: bitmap, flipped: false)
        graphics.imageInterpolation = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let small = bitmap.makeImage(),
              let tinted = harmonized(NSBitmapImageRep(cgImage: small)),
              let tintedImage = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return smoothUpscale(tintedImage, to: 48, space: space)
    }

    /// Bilinear/bicubic stretching of the tiny image: a smooth gradient between its colors.
    private static func smoothUpscale(_ image: CGImage, to side: Int, space: CGColorSpace) -> NSImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: side, height: side))
    }

    /// Pulls every color of the blurred artwork toward its dominant hue, so a multicolored cover doesn't give
    /// clashing bars (a red bar next to a green one): the arrangement and light/dark pattern stay, the hues become
    /// neighbors. Saturation and brightness are lifted so the bars glow; a gray cover stays soft white.
    private static func harmonized(_ pixels: NSBitmapImageRep) -> NSImage? {
        let width = pixels.pixelsWide, height = pixels.pixelsHigh
        var hsb: [(h: CGFloat, s: CGFloat, b: CGFloat)] = []
        hsb.reserveCapacity(width * height)
        var histogram = [CGFloat](repeating: 0, count: 24)
        var meanSaturation: CGFloat = 0
        for y in 0..<height {
            for x in 0..<width {
                let color = (pixels.colorAt(x: x, y: y) ?? .white).usingColorSpace(.sRGB) ?? .white
                let item = (h: color.hueComponent, s: color.saturationComponent, b: color.brightnessComponent)
                hsb.append(item)
                meanSaturation += item.s
                histogram[min(Int(item.h * 24), 23)] += item.s * item.b
            }
        }
        meanSaturation /= CGFloat(max(hsb.count, 1))
        // Dominant hue: the heaviest bin of the (circularly smoothed) histogram.
        let smoothed = (0..<24).map { histogram[($0 + 23) % 24] * 0.5 + histogram[$0] + histogram[($0 + 1) % 24] * 0.5 }
        let dominant = (CGFloat(smoothed.indices.max { smoothed[$0] < smoothed[$1] } ?? 0) + 0.5) / 24
        let gray = meanSaturation < 0.12

        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let item = hsb[y * width + x]
                let color: NSColor
                if gray {
                    let ramp = 1 - CGFloat(y) / CGFloat(max(height - 1, 1))      // 0 at the bottom, 1 at the top
                    let level = 0.7 + 0.22 * item.b + 0.12 * ramp
                    color = NSColor(white: min(level, 1), alpha: 1)
                } else {
                    // Distance to the dominant hue on the color wheel, shrunk and capped at ±40°.
                    var delta = item.h - dominant
                    if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
                    let ramp = 1 - CGFloat(y) / CGFloat(max(height - 1, 1))      // 0 at the bottom, 1 at the top
                    // The tip drifts a few degrees along the wheel: a calm two-tone gradient without patches.
                    // Nearly white/gray pixels have a meaningless hue: they follow the dominant one.
                    let trust = min(item.s / 0.25, 1)
                    let hue = dominant + max(min(delta * 0.35 * trust, 35.0 / 360), -35.0 / 360) + 16.0 / 360 * ramp
                    // Each bar fades from a deeper color at its foot to a lighter one at its tip.
                    let saturation = min(max(item.s * 1.2 + 0.12, 0.66), 0.96) * (1 - 0.18 * ramp)
                    let brightness = min(max(0.5 + 0.5 * item.b, 0.76), 0.96) + 0.1 * ramp
                    color = NSColor(hue: (hue + 1).truncatingRemainder(dividingBy: 1),
                                    saturation: min(saturation, 1), brightness: min(brightness, 1), alpha: 1)
                }
                let rgb = color.usingColorSpace(.sRGB) ?? .white
                // The bitmap's rows run top to bottom, like `pixels`.
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(max(0, min(255, rgb.redComponent * 255)))
                bytes[offset + 1] = UInt8(max(0, min(255, rgb.greenComponent * 255)))
                bytes[offset + 2] = UInt8(max(0, min(255, rgb.blueComponent * 255)))
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
