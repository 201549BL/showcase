import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import Foundation

final class FrameCompositor {
    private let project: RecordingProject
    private let geometry: CanvasGeometry
    private let cursorPath: CursorPath
    private let cameraEvaluator: CameraEvaluator
    private let cursorImage: CIImage?
    private let cursorHotSpot: CGPoint
    private let cursorNativeSize: CGSize
    private let clickEvents: [LocalizedInputEvent]
    private let canvasRect: CGRect
    private let screenMask: CIImage
    private let transparentCanvas: CIImage
    private let shadowImage: CIImage
    private let backgroundImage: CIImage

    init(
        project: RecordingProject,
        events: [RecordedInputEvent],
        quality: ExportQuality,
        maximumCanvasDimension: Double? = nil
    ) {
        self.project = project
        let builtGeometry = CanvasGeometry(
            project: project,
            quality: quality,
            maximumCanvasDimension: maximumCanvasDimension
        )
        geometry = builtGeometry
        let builtCanvasRect = CGRect(origin: .zero, size: builtGeometry.canvasSize)
        canvasRect = builtCanvasRect
        screenMask = Self.roundedRectangle(
            rect: builtGeometry.screenRect,
            radius: builtGeometry.scaledCornerRadius,
            color: .white
        )
        transparentCanvas = CIImage(color: .clear).cropped(to: builtCanvasRect)
        shadowImage = Self.makeShadow(
            canvasRect: builtCanvasRect,
            geometry: builtGeometry
        )
        backgroundImage = Self.makeBackground(
            canvasRect: builtCanvasRect,
            canvas: project.canvas
        )

        let localizedEvents = InputEventLocalizer().localize(
            events,
            source: project.recording.source,
            pixelWidth: project.recording.width,
            pixelHeight: project.recording.height
        )
        let builtCursorPath = CursorPath(
            events: localizedEvents,
            smoothing: project.cursor.smoothing,
            hideAfter: project.cursor.hideAfter
        )
        cursorPath = builtCursorPath
        let builtCursorHotSpot = CGPoint(x: 2, y: 2)
        let builtCursorNativeSize = CGSize(width: 32, height: 48)
        cursorHotSpot = builtCursorHotSpot
        cursorNativeSize = builtCursorNativeSize
        let cursorCanvasScale = max(
            0,
            project.cursor.scale * builtGeometry.canvasSize.height / 1_080
        )
        let halfViewportWidth = max(1, builtGeometry.screenRect.width / 2)
        let halfViewportHeight = max(1, builtGeometry.screenRect.height / 2)
        let cursorViewportInsets = CursorViewportInsets(
            left: builtCursorHotSpot.x * cursorCanvasScale / halfViewportWidth,
            right: (builtCursorNativeSize.width - builtCursorHotSpot.x)
                * cursorCanvasScale / halfViewportWidth,
            top: builtCursorHotSpot.y * cursorCanvasScale / halfViewportHeight,
            bottom: (builtCursorNativeSize.height - builtCursorHotSpot.y)
                * cursorCanvasScale / halfViewportHeight
        )
        cameraEvaluator = CameraEvaluator(
            segments: project.zoomSegments.sorted { $0.startTime < $1.startTime },
            sourceSize: CGSize(
                width: project.recording.width,
                height: project.recording.height
            ),
            duration: project.recording.duration,
            cursorPath: builtCursorPath,
            cursorViewportInsets: cursorViewportInsets
        )
        clickEvents = localizedEvents.filter { $0.isPrimaryClick && $0.position != nil }

        let renderedCursor = Self.makeCursorImage()
        cursorImage = renderedCursor
    }

    var renderSize: CGSize { geometry.canvasSize }

    func cameraState(at time: Double) -> CameraState {
        cameraEvaluator.state(at: time)
    }

    func render(sourceImage: CIImage, at compositionTime: CMTime) -> CIImage {
        let time = max(0, CMTimeGetSeconds(compositionTime))
        let sourceSize = CGSize(
            width: project.recording.width,
            height: project.recording.height
        )
        let camera = cameraEvaluator.state(at: time)
        let transform = cameraTransform(camera, sourceSize: sourceSize)

        let normalizedSource = sourceImage.transformed(
            by: CGAffineTransform(
                translationX: -sourceImage.extent.minX,
                y: -sourceImage.extent.minY
            )
        )
        var screenContent = normalizedSource.transformed(by: transform)

        if let cursorFrame = cursorPath.frame(at: time), cursorFrame.opacity > 0 {
            let cursor = renderCursor(frame: cursorFrame, cameraTransform: transform)
            screenContent = cursor.composited(over: screenContent)
        }

        if project.cursor.showsClickAnimation,
           let clickRing = renderClickRing(at: time, cameraTransform: transform) {
            screenContent = clickRing.composited(over: screenContent)
        }

        let clippedScreen = screenContent.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparentCanvas,
                kCIInputMaskImageKey: screenMask
            ]
        )

        return clippedScreen
            .composited(over: shadowImage)
            .composited(over: backgroundImage)
            .cropped(to: canvasRect)
    }

    private func cameraTransform(_ camera: CameraState, sourceSize: CGSize) -> CGAffineTransform {
        let baseScale = geometry.screenRect.width / sourceSize.width
        let scale = baseScale * camera.scale
        let focusY = sourceSize.height - camera.focusPoint.y
        return CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: geometry.screenRect.midX - (camera.focusPoint.x * scale),
            ty: geometry.screenRect.midY - (focusY * scale)
        )
    }

    private func renderCursor(
        frame: CursorPath.Frame,
        cameraTransform: CGAffineTransform
    ) -> CIImage {
        guard let cursorImage else { return CIImage.empty() }

        let sourcePoint = CGPoint(
            x: frame.position.x,
            y: Double(project.recording.height) - frame.position.y
        )
        let canvasPoint = sourcePoint.applying(cameraTransform)
        let designScale = geometry.canvasSize.height / 1_080
        let targetScale = project.cursor.scale * designScale
        let nativeWidth = max(1, cursorNativeSize.width)
        let bitmapScale = cursorImage.extent.width / nativeWidth
        let imageScale = targetScale / bitmapScale
        let scaledHeight = cursorImage.extent.height * imageScale
        let hotSpotX = cursorHotSpot.x * targetScale
        let hotSpotYFromBottom = scaledHeight - (cursorHotSpot.y * targetScale)

        let transform = CGAffineTransform(
            a: imageScale,
            b: 0,
            c: 0,
            d: imageScale,
            tx: canvasPoint.x - hotSpotX,
            ty: canvasPoint.y - hotSpotYFromBottom
        )
        let image = cursorImage.transformed(by: transform)
        guard frame.opacity < 0.999 else { return image }

        return image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: frame.opacity)
            ]
        )
    }

    private func renderClickRing(
        at time: Double,
        cameraTransform: CGAffineTransform
    ) -> CIImage? {
        guard
            let click = clickEvents.last(where: { $0.timestamp <= time }),
            let position = click.position
        else { return nil }

        let age = time - click.timestamp
        guard age >= 0, age <= 0.45 else { return nil }

        let sourcePoint = CGPoint(
            x: position.x,
            y: Double(project.recording.height) - position.y
        )
        let canvasPoint = sourcePoint.applying(cameraTransform)
        let progress = age / 0.45
        let designScale = geometry.canvasSize.height / 1_080
        let radius = (12 + (28 * progress)) * designScale
        let opacity = max(0, 0.7 * (1 - progress))
        let outerRect = CGRect(
            x: canvasPoint.x - radius,
            y: canvasPoint.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let strokeWidth = max(1, 3 * designScale)
        let innerRadius = max(0, radius - strokeWidth)
        let innerRect = outerRect.insetBy(dx: strokeWidth, dy: strokeWidth)
        let outer = Self.roundedRectangle(
            rect: outerRect,
            radius: radius,
            color: CIColor(red: 1, green: 1, blue: 1, alpha: opacity)
        )
        let inner = Self.roundedRectangle(
            rect: innerRect,
            radius: innerRadius,
            color: .white
        )
        return outer.applyingFilter(
            "CISourceOutCompositing",
            parameters: [kCIInputBackgroundImageKey: inner]
        )
    }

    private static func makeBackground(
        canvasRect: CGRect,
        canvas: CanvasSettings
    ) -> CIImage {
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: 0, y: 0)
        filter.point1 = CGPoint(x: canvasRect.maxX, y: canvasRect.maxY)
        filter.color0 = CIColor(hex: canvas.backgroundStartHex)
        filter.color1 = CIColor(hex: canvas.backgroundEndHex)
        return filter.outputImage?.cropped(to: canvasRect)
            ?? CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.22)).cropped(to: canvasRect)
    }

    private static func makeShadow(
        canvasRect: CGRect,
        geometry: CanvasGeometry
    ) -> CIImage {
        guard geometry.scaledShadowRadius > 0 else {
            return CIImage(color: .clear).cropped(to: canvasRect)
        }

        let shape = roundedRectangle(
            rect: geometry.screenRect,
            radius: geometry.scaledCornerRadius,
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.42)
        )
        return shape
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: geometry.scaledShadowRadius]
            )
            .transformed(by: CGAffineTransform(translationX: 0, y: -geometry.scaledShadowRadius * 0.3))
            .cropped(to: canvasRect)
    }

    private static func roundedRectangle(
        rect: CGRect,
        radius: Double,
        color: CIColor
    ) -> CIImage {
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        filter.radius = Float(max(0, radius))
        filter.color = color
        return filter.outputImage ?? CIImage(color: color).cropped(to: rect)
    }

    private static func makeCursorImage() -> CIImage? {
        let width = 64
        let height = 96
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 91))
        path.addLine(to: CGPoint(x: 5, y: 20))
        path.addLine(to: CGPoint(x: 24, y: 38))
        path.addLine(to: CGPoint(x: 37, y: 8))
        path.addLine(to: CGPoint(x: 50, y: 14))
        path.addLine(to: CGPoint(x: 37, y: 44))
        path.addLine(to: CGPoint(x: 61, y: 44))
        path.closeSubpath()

        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0.05, alpha: 1))
        context.setLineWidth(5)
        context.strokePath()

        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }
}

private extension CIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red: Double
        let green: Double
        let blue: Double

        if cleaned.count == 6 {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        } else {
            red = 0.25
            green = 0.2
            blue = 0.55
        }
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
