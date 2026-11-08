import AppKit
import CoreImage

/// The artwork blurred beyond recognition — only its colors and their arrangement are left. The visualizer's bars
/// are cut out of it.
enum BlurredArtwork {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func make(from image: NSImage) -> NSImage? {
        let side = 40
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let small = bitmap.makeImage() else { return nil }

        // Blur, then lift the saturation and brightness so the bars glow even on a dull cover.
        let blurred = CIImage(cgImage: small).clampedToExtent()
            .applyingGaussianBlur(sigma: 7)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.5, kCIInputBrightnessKey: 0.1,
                                                            kCIInputContrastKey: 1.1])
            .cropped(to: rect)
        guard let result = context.createCGImage(blurred, from: rect) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: side, height: side))
    }
}
