import CoreGraphics
import Foundation

struct TimelineGeometry: Equatable {
    let duration: Double
    let width: Double

    func x(for time: Double) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        return min(width, max(0, time / duration * width))
    }

    func time(for x: Double) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        return min(duration, max(0, x / width * duration))
    }

    func width(from startTime: Double, to endTime: Double) -> Double {
        max(0, x(for: endTime) - x(for: startTime))
    }

    func timeDelta(for xDelta: Double) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        return xDelta / width * duration
    }
}

/// Time marks stay on round intervals and leave enough room for their labels.
struct TimelineRuler {
    let duration: Double
    let width: Double

    var step: Double {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0 else { return 1 }
        let intervals = min(20, max(1, floor(width / 90)))
        let raw = max(0.1, duration / intervals)
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let factor = [1.0, 2, 5, 10].first { $0 >= normalized } ?? 10
        return factor * magnitude
    }

    var ticks: [Double] {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0 else { return [0] }
        let count = min(20, Int(floor(duration / step)))
        return (0...count).map { Double($0) * step }
    }

    func label(for time: Double) -> String {
        if step < 1 {
            return String(format: "%02d:%04.1f", Int(time) / 60, time.truncatingRemainder(dividingBy: 60))
        }
        let seconds = Int(time.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

enum TimelineBlockStacking {
    static func zIndex(isSelected: Bool, order: Int) -> Double {
        isSelected ? 10_000 : Double(order)
    }
}

struct TimelineDragProjection: Equatable {
    let initialTime: Double
    let pointerStartX: Double
    let geometry: TimelineGeometry

    func time(atPointerX pointerX: Double) -> Double {
        initialTime + geometry.timeDelta(for: pointerX - pointerStartX)
    }
}

struct PreviewFocusMapper: Equatable {
    let viewSize: CGSize
    let canvasSize: CGSize
    let screenRect: CGRect
    let sourceSize: CGSize
    let cameraFocus: CGPoint
    let cameraScale: Double

    var displayedCanvasRect: CGRect {
        guard
            viewSize.width > 0,
            viewSize.height > 0,
            canvasSize.width > 0,
            canvasSize.height > 0
        else { return .zero }

        let scale = min(viewSize.width / canvasSize.width, viewSize.height / canvasSize.height)
        let size = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func sourcePoint(for viewLocation: CGPoint) -> CGPoint? {
        let canvasRect = displayedCanvasRect
        guard
            canvasRect.width > 0,
            canvasRect.height > 0,
            canvasRect.contains(viewLocation),
            sourceSize.width > 0,
            sourceSize.height > 0,
            screenRect.width > 0
        else { return nil }

        let displayScale = canvasRect.width / canvasSize.width
        let canvasPoint = CGPoint(
            x: (viewLocation.x - canvasRect.minX) / displayScale,
            y: (viewLocation.y - canvasRect.minY) / displayScale
        )
        let topLeftScreenRect = CGRect(
            x: screenRect.minX,
            y: canvasSize.height - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
        guard topLeftScreenRect.contains(canvasPoint) else { return nil }

        let screenCenter = CGPoint(
            x: screenRect.midX,
            y: canvasSize.height - screenRect.midY
        )
        let sourceToCanvasScale = screenRect.width / sourceSize.width
        let renderedScale = sourceToCanvasScale * max(1, cameraScale)
        let point = CGPoint(
            x: cameraFocus.x + (canvasPoint.x - screenCenter.x) / renderedScale,
            y: cameraFocus.y + (canvasPoint.y - screenCenter.y) / renderedScale
        )

        return CGPoint(
            x: min(sourceSize.width, max(0, point.x)),
            y: min(sourceSize.height, max(0, point.y))
        )
    }
}

struct PreviewViewboxMapper: Equatable {
    let viewSize: CGSize
    let canvasSize: CGSize
    let screenRect: CGRect
    let sourceSize: CGSize

    var displayedCanvasRect: CGRect {
        guard
            viewSize.width > 0,
            viewSize.height > 0,
            canvasSize.width > 0,
            canvasSize.height > 0
        else { return .zero }

        let scale = min(viewSize.width / canvasSize.width, viewSize.height / canvasSize.height)
        let size = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    var displayedScreenRect: CGRect {
        let canvasRect = displayedCanvasRect
        guard canvasSize.width > 0 else { return .zero }
        let scale = canvasRect.width / canvasSize.width
        return CGRect(
            x: canvasRect.minX + screenRect.minX * scale,
            y: canvasRect.minY + (canvasSize.height - screenRect.maxY) * scale,
            width: screenRect.width * scale,
            height: screenRect.height * scale
        )
    }

    func viewboxRect(focusPoint: CGPoint, scale: Double) -> CGRect {
        let screen = displayedScreenRect
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let zoom = max(1, scale)
        let sourceWidth = sourceSize.width / zoom
        let sourceHeight = sourceSize.height / zoom
        let clampedFocus = clampedFocusPoint(focusPoint, scale: zoom)
        return CGRect(
            x: screen.minX + (clampedFocus.x - sourceWidth / 2) / sourceSize.width * screen.width,
            y: screen.minY + (clampedFocus.y - sourceHeight / 2) / sourceSize.height * screen.height,
            width: screen.width / zoom,
            height: screen.height / zoom
        )
    }

    func focusPoint(
        moving focusPoint: CGPoint,
        by translation: CGSize,
        scale: Double
    ) -> CGPoint {
        let screen = displayedScreenRect
        guard screen.width > 0, screen.height > 0 else { return focusPoint }
        let proposed = CGPoint(
            x: focusPoint.x + translation.width / screen.width * sourceSize.width,
            y: focusPoint.y + translation.height / screen.height * sourceSize.height
        )
        return clampedFocusPoint(proposed, scale: scale)
    }

    func scale(
        resizingHandleTo location: CGPoint,
        focusPoint: CGPoint,
        initialScale: Double,
        allowedRange: ClosedRange<Double>
    ) -> Double {
        let initialRect = viewboxRect(focusPoint: focusPoint, scale: initialScale)
        guard initialRect.width > 0, initialRect.height > 0 else { return initialScale }
        let horizontalRatio = abs(location.x - initialRect.midX) / (initialRect.width / 2)
        let verticalRatio = abs(location.y - initialRect.midY) / (initialRect.height / 2)
        let sizeRatio = max(0.05, (horizontalRatio + verticalRatio) / 2)
        return min(
            allowedRange.upperBound,
            max(allowedRange.lowerBound, initialScale / sizeRatio)
        )
    }

    func clampedFocusPoint(_ point: CGPoint, scale: Double) -> CGPoint {
        let zoom = max(1, scale)
        let halfWidth = sourceSize.width / (2 * zoom)
        let halfHeight = sourceSize.height / (2 * zoom)
        return CGPoint(
            x: min(sourceSize.width - halfWidth, max(halfWidth, point.x)),
            y: min(sourceSize.height - halfHeight, max(halfHeight, point.y))
        )
    }
}
