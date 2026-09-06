import AppKit
import Foundation

// Reproducible vector icon; no external fonts or image assets.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856), xRadius: 190, yRadius: 190)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.28, green: 0.19, blue: 0.78, alpha: 1),
                                  ending: NSColor(srgbRed: 0.70, green: 0.36, blue: 0.99, alpha: 1))!
        gradient.draw(in: tile, angle: 60)
        NSColor.white.withAlphaComponent(0.24).setStroke()
        tile.lineWidth = 3
        tile.stroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: 219, y: 302, width: 586, height: 422), xRadius: 54, yRadius: 54)
        NSColor.white.withAlphaComponent(0.12).setFill()
        screen.fill()
        NSColor.white.withAlphaComponent(0.94).setStroke()
        screen.lineWidth = 28
        screen.stroke()
        let play = NSBezierPath()
        play.move(to: NSPoint(x: 461, y: 407))
        play.line(to: NSPoint(x: 461, y: 617))
        play.line(to: NSPoint(x: 637, y: 512))
        play.close()
        NSColor.white.setFill()
        play.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
