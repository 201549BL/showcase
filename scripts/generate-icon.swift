import AppKit
import Foundation

// Package the approved artwork at every macOS icon resolution, including Retina.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artworkURL = root.appendingPathComponent("Resources/AppIcon.png")
guard let artwork = NSImage(contentsOf: artworkURL) else {
    fatalError("Missing app icon artwork: \(artworkURL.path)")
}
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            fatalError("Cannot allocate icon bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        // Standard Dock padding and rounded-square silhouette. Bleed the artwork slightly
        // past this mask so the icon edge remains clean at small display sizes.
        let tile = NSRect(x: 84, y: 84, width: 856, height: 856)
        NSBezierPath(roundedRect: tile, xRadius: 190, yRadius: 190).addClip()
        let source = NSRect(origin: .zero, size: artwork.size).insetBy(dx: 30, dy: 30)
        artwork.draw(in: tile, from: source, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode icon PNG")
        }
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
