import AppKit
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
    private let motionBlurAmount: Double
    private let cursorArtworks: [RecordedInputEvent.CursorStyle: CursorArtwork]
    private let cameraFrameProvider: CameraFrameProviding?
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
        maximumCanvasDimension: Double? = nil,
        cameraFrameProvider: CameraFrameProviding? = nil,
        backgroundImageURL: URL? = nil
    ) {
        var project = project
        project.synchronizeCameraEffects()
        self.project = project
        self.cameraFrameProvider = cameraFrameProvider
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
            canvas: project.canvas,
            imageURL: backgroundImageURL
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
        motionBlurAmount = min(1, max(0, project.resolvedMotionBlur.amount))
        let builtCursorArtworks = Self.makeCursorArtworks(settings: project.cursor)
        cursorArtworks = builtCursorArtworks
        let cursorCanvasScale = max(
            0,
            project.cursor.scale * builtGeometry.canvasSize.height / 1_080
        )
        let halfViewportWidth = max(1, builtGeometry.screenRect.width / 2)
        let halfViewportHeight = max(1, builtGeometry.screenRect.height / 2)
        let cursorViewportInsets = builtCursorArtworks.values.reduce(
            CursorViewportInsets.zero
        ) { insets, artwork in
            let artworkScale = cursorCanvasScale * artwork.presentationScale
            return CursorViewportInsets(
                left: max(
                    insets.left,
                    artwork.hotSpot.x * artworkScale / halfViewportWidth
                ),
                right: max(
                    insets.right,
                    (artwork.nativeSize.width - artwork.hotSpot.x)
                        * artworkScale / halfViewportWidth
                ),
                top: max(
                    insets.top,
                    artwork.hotSpot.y * artworkScale / halfViewportHeight
                ),
                bottom: max(
                    insets.bottom,
                    (artwork.nativeSize.height - artwork.hotSpot.y)
                        * artworkScale / halfViewportHeight
                )
            )
        }
        let sortedZoomSegments = project.zoomSegments.sorted { $0.startTime < $1.startTime }
        let builtCameraEvaluator = CameraEvaluator(
            segments: sortedZoomSegments,
            sourceSize: CGSize(
                width: project.recording.width,
                height: project.recording.height
            ),
            duration: project.recording.duration,
            cursorPath: builtCursorPath,
            cursorViewportInsets: cursorViewportInsets,
            motionStyle: project.resolvedZoomBehavior.resolvedMotionStyle
        )
        cameraEvaluator = builtCameraEvaluator
        clickEvents = localizedEvents.filter { $0.isPrimaryClick && $0.position != nil }

    }

    var renderSize: CGSize { geometry.canvasSize }

    func cameraState(at time: Double) -> CameraState {
        cameraEvaluator.state(at: time)
    }

    func render(sourceImage: CIImage, at compositionTime: CMTime) -> CIImage {
        let time = max(0, CMTimeGetSeconds(compositionTime))
        let normalizedSource = sourceImage.transformed(
            by: CGAffineTransform(
                translationX: -sourceImage.extent.minX,
                y: -sourceImage.extent.minY
            )
        )
        var composedFrame = motionBlurredScreenContent(
            sourceImage: normalizedSource,
            at: time
        )
            .composited(over: backgroundImage)
            .cropped(to: canvasRect)
        if let cameraOverlay = renderCameraOverlay(at: compositionTime) {
            composedFrame = cameraOverlay.composited(over: composedFrame)
        }
        return composedFrame.cropped(to: canvasRect)
    }

    private func renderCameraOverlay(at time: CMTime) -> CIImage? {
        let seconds = max(0, CMTimeGetSeconds(time))
        guard
            let settings = project.cameraSettings(at: seconds),
            let source = cameraFrameProvider?.frame(at: time),
            !source.extent.isEmpty
        else { return nil }

        let size = project.emphasizedCameraSize(settings.size, at: seconds)
        let diameter = max(
            96 * geometry.canvasSize.height / 1_080,
            min(geometry.canvasSize.width, geometry.canvasSize.height) * size
        )
        let margin = max(16, diameter * 0.08)
        let rect = cameraOverlayRect(
            diameter: diameter,
            margin: margin,
            corner: settings.corner
        )
        let normalized = source.transformed(
            by: CGAffineTransform(
                translationX: -source.extent.minX,
                y: -source.extent.minY
            )
        )
        let oriented = settings.resolvedIsMirrored ? normalized.transformed(
            by: CGAffineTransform(
                a: -1,
                b: 0,
                c: 0,
                d: 1,
                tx: normalized.extent.width,
                ty: 0
            )
        ) : normalized
        let cropSide = min(oriented.extent.width, oriented.extent.height)
        let cropRect = CGRect(
            x: oriented.extent.midX - cropSide / 2,
            y: oriented.extent.midY - cropSide / 2,
            width: cropSide,
            height: cropSide
        )
        let scale = diameter / cropSide
        let cameraImage = oriented
            .cropped(to: cropRect)
            .transformed(
                by: CGAffineTransform(
                    a: scale,
                    b: 0,
                    c: 0,
                    d: scale,
                    tx: rect.minX - cropRect.minX * scale,
                    ty: rect.minY - cropRect.minY * scale
                )
            )
        let cameraCornerRadius = diameter * 0.25
        let mask = Self.roundedRectangle(
            rect: rect,
            radius: cameraCornerRadius,
            color: .white
        )
        let clippedCamera = cameraImage.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparentCanvas,
                kCIInputMaskImageKey: mask
            ]
        )
        let borderWidth = max(2, 4 * geometry.canvasSize.height / 1_080)
        let innerRect = rect.insetBy(dx: borderWidth, dy: borderWidth)
        let inner = Self.roundedRectangle(
            rect: innerRect,
            radius: max(0, cameraCornerRadius - borderWidth),
            color: .white
        )
        let border = mask.applyingFilter(
            "CISourceOutCompositing",
            parameters: [kCIInputBackgroundImageKey: inner]
        )
        let shadow = mask
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.32)
                ]
            )
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: max(4, diameter * 0.045)]
            )
            .transformed(by: CGAffineTransform(translationX: 0, y: -diameter * 0.025))
        return border
            .composited(over: clippedCamera)
            .composited(over: shadow)
    }

    private func cameraOverlayRect(
        diameter: Double,
        margin: Double,
        corner: CameraOverlaySettings.Corner
    ) -> CGRect {
        Self.cameraOverlayRect(
            in: canvasRect,
            diameter: diameter,
            margin: margin,
            corner: corner
        )
    }

    private static func cameraOverlayRect(
        in canvasRect: CGRect,
        diameter: Double,
        margin: Double,
        corner: CameraOverlaySettings.Corner
    ) -> CGRect {
        let left = canvasRect.minX + margin
        let right = canvasRect.maxX - margin - diameter
        let bottom = canvasRect.minY + margin
        let top = canvasRect.maxY - margin - diameter
        let origin: CGPoint
        switch corner {
        case .topLeft: origin = CGPoint(x: left, y: top)
        case .topRight: origin = CGPoint(x: right, y: top)
        case .bottomLeft: origin = CGPoint(x: left, y: bottom)
        case .bottomRight: origin = CGPoint(x: right, y: bottom)
        }
        return CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
    }

    private func motionBlurredScreenContent(
        sourceImage: CIImage,
        at time: Double
    ) -> CIImage {
        let current = screenContent(sourceImage: sourceImage, at: time)
        guard motionBlurAmount > 0 else { return current }

        // The amount is expressed as a fraction of one 60 fps frame of exposure.
        // Sampling camera and cursor poses produces true directional trails while
        // leaving stationary content untouched.
        let exposureDuration = motionBlurAmount / 60
        let startTime = max(0, time - exposureDuration / 2)
        let projectEndTime = project.recording.duration ?? (time + exposureDuration / 2)
        let endTime = min(projectEndTime, time + exposureDuration / 2)
        guard hasMotion(from: startTime, to: endTime) else { return current }

        let sampleCount = 5
        let sampleImages = (0..<sampleCount).map { index in
            let progress = Double(index) / Double(sampleCount - 1)
            let sampleTime = startTime + ((endTime - startTime) * progress)
            return screenContent(sourceImage: sourceImage, at: sampleTime)
        }
        return Self.average(sampleImages)
    }

    private func screenContent(sourceImage: CIImage, at time: Double) -> CIImage {
        let sourceSize = CGSize(
            width: project.recording.width,
            height: project.recording.height
        )
        let camera = cameraEvaluator.state(at: time)
        let transform = cameraTransform(camera, sourceSize: sourceSize)
        var content = sourceImage.transformed(by: transform)

        if let cursorFrame = cursorPath.frame(at: time), cursorFrame.opacity > 0 {
            let cursor = renderCursor(frame: cursorFrame, cameraTransform: transform)
            content = cursor.composited(over: content)
        }
        if project.cursor.showsClickAnimation,
           let clickRing = renderClickRing(at: time, cameraTransform: transform) {
            content = clickRing.composited(over: content)
        }

        // Move the authored recording card as one layer. Its mask and shadow keep
        // their proportions and leave the canvas naturally as the camera approaches.
        let layerTransform = CGAffineTransform(
            a: camera.scale, b: 0, c: 0, d: camera.scale,
            tx: transform.tx - geometry.screenRect.minX * camera.scale,
            ty: transform.ty - geometry.screenRect.minY * camera.scale
        )
        let mask = screenMask.transformed(by: layerTransform)
        let clipped = content.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparentCanvas,
                kCIInputMaskImageKey: mask
            ]
        )
        return clipped
            .composited(over: shadowImage.transformed(by: layerTransform))
            .cropped(to: canvasRect)
    }

    private func hasMotion(from startTime: Double, to endTime: Double) -> Bool {
        guard endTime > startTime else { return false }

        let startCamera = cameraEvaluator.state(at: startTime)
        let endCamera = cameraEvaluator.state(at: endTime)
        let focusDistance = hypot(
            endCamera.focusPoint.x - startCamera.focusPoint.x,
            endCamera.focusPoint.y - startCamera.focusPoint.y
        )
        if focusDistance > 0.1 || abs(endCamera.scale - startCamera.scale) > 0.0001 {
            return true
        }

        guard
            let startCursor = cursorPath.frame(at: startTime),
            let endCursor = cursorPath.frame(at: endTime)
        else { return false }
        return hypot(
            endCursor.position.x - startCursor.position.x,
            endCursor.position.y - startCursor.position.y
        ) > 0.1
    }

    private static func average(_ images: [CIImage]) -> CIImage {
        guard let first = images.first else { return CIImage.empty() }
        return images.dropFirst().enumerated().reduce(first) { result, pair in
            let accumulatedSampleCount = Double(pair.offset + 2)
            return pair.element.applyingFilter(
                "CIMix",
                parameters: [
                    kCIInputBackgroundImageKey: result,
                    "inputAmount": 1 / accumulatedSampleCount
                ]
            )
        }
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
        guard
            let artwork = cursorArtworks[frame.cursorStyle]
                ?? cursorArtworks[.arrow]
        else { return CIImage.empty() }

        let sourcePoint = CGPoint(
            x: frame.position.x,
            y: Double(project.recording.height) - frame.position.y
        )
        let canvasPoint = sourcePoint.applying(cameraTransform)
        let designScale = geometry.canvasSize.height / 1_080
        let targetScale = project.cursor.scale * designScale * artwork.presentationScale
        let nativeWidth = max(1, artwork.nativeSize.width)
        let bitmapScale = artwork.image.extent.width / nativeWidth
        let imageScale = targetScale / bitmapScale
        let scaledHeight = artwork.image.extent.height * imageScale
        let hotSpotX = artwork.hotSpot.x * targetScale
        let hotSpotYFromBottom = scaledHeight - (artwork.hotSpot.y * targetScale)

        let transform = CGAffineTransform(
            a: imageScale,
            b: 0,
            c: 0,
            d: imageScale,
            tx: canvasPoint.x - hotSpotX,
            ty: canvasPoint.y - hotSpotYFromBottom
        )
        let image = artwork.image.transformed(by: transform)
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
        canvas: CanvasSettings,
        imageURL: URL?
    ) -> CIImage {
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: 0, y: 0)
        filter.point1 = CGPoint(x: canvasRect.maxX, y: canvasRect.maxY)
        filter.color0 = CIColor(hex: canvas.backgroundStartHex)
        filter.color1 = CIColor(hex: canvas.backgroundEndHex)
        let gradient = filter.outputImage?.cropped(to: canvasRect)
            ?? CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.22)).cropped(to: canvasRect)
        guard let imageURL,
              let image = BackgroundImages.image(at: imageURL, maximumDimension: Int(max(canvasRect.width, canvasRect.height)))
        else { return gradient }
        let source = CIImage(cgImage: image)
        let scale = max(canvasRect.width / source.extent.width, canvasRect.height / source.extent.height)
        return source.transformed(by: CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: canvasRect.midX - source.extent.midX * scale,
            ty: canvasRect.midY - source.extent.midY * scale
        )).composited(over: gradient).cropped(to: canvasRect)
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

    private static func makeCursorArtworks(settings: CursorSettings) -> [RecordedInputEvent.CursorStyle: CursorArtwork] {
        // Bibata hotspots are measured from the top-left of its 256 × 256 SVGs.
        let definitions: [(RecordedInputEvent.CursorStyle, String, CGFloat, CGFloat)] = [
            (.arrow, "left_ptr", 55, 17),
            (.pointingHand, "hand2", 114, 18),
            (.iBeam, "xterm", 128, 128),
            (.openHand, "hand1", 144, 79),
            (.closedHand, "grabbing", 128, 66),
            (.crosshair, "crosshair", 128, 128),
            (.resizeHorizontal, "sb_h_double_arrow", 128, 128),
            (.resizeVertical, "sb_v_double_arrow", 128, 128),
            (.operationNotAllowed, "circle", 55, 17),
            (.dragCopy, "copy", 55, 17),
            (.dragLink, "link", 55, 17)
        ]
        let resources = Bundle.main.resourceURL?
            .appendingPathComponent("Showcase_Showcase.bundle")
        let bundle = resources.flatMap { Bundle(url: $0) } ?? Bundle.module
        return Dictionary(uniqueKeysWithValues: definitions.map { style, name, x, y in
            guard let url = bundle.url(
                forResource: name, withExtension: "png", subdirectory: "Bibata"
            ), let image = CIImage(contentsOf: url) else {
                preconditionFailure("Missing bundled Bibata cursor: \(name)")
            }
            let size: CGFloat = 48
            return (style, CursorArtwork(
                image: recolorCursor(image, settings: settings),
                hotSpot: CGPoint(x: x * size / 256, y: y * size / 256),
                nativeSize: CGSize(width: size, height: size),
                presentationScale: 1
            ))
        })
    }

    private static func recolorCursor(_ image: CIImage, settings: CursorSettings) -> CIImage {
        let fill = CIColor(hex: settings.resolvedFillHex)
        let outline = CIColor(hex: settings.resolvedOutlineHex)
        // Ice artwork is grayscale: black is outline, white is fill. Mapping
        // that ramp preserves antialiased edges and the original alpha channel.
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: fill.red - outline.red, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: fill.green - outline.green, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: fill.blue - outline.blue, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: outline.red, y: outline.green, z: outline.blue, w: 0)
        ])
    }

}

private struct CursorArtwork {
    let image: CIImage
    let hotSpot: CGPoint
    let nativeSize: CGSize
    let presentationScale: Double
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
