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
