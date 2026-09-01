import CoreGraphics
import Foundation

struct CameraState: Equatable {
    let scale: Double
    let focusPoint: CGPoint
}

struct CameraEvaluator {
    let segments: [ZoomSegment]
    let sourceSize: CGSize
    var zoomOutDuration = 0.5

    func state(at time: Double) -> CameraState {
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        guard let segment = segments.first(where: { time >= $0.startTime && time <= $0.endTime }) else {
            return CameraState(scale: 1, focusPoint: center)
        }

        let progress: Double
        if time < segment.focusTime {
            let duration = max(0.001, segment.focusTime - segment.startTime)
            progress = eased((time - segment.startTime) / duration)
        } else {
            let exitStart = max(segment.focusTime, segment.endTime - zoomOutDuration)
            if time <= exitStart {
                progress = 1
            } else {
                let duration = max(0.001, segment.endTime - exitStart)
                progress = 1 - eased((time - exitStart) / duration)
            }
        }

        let target = clampedFocus(segment.focusPoint.cgPoint, scale: max(1, segment.scale))
        return CameraState(
            scale: 1 + ((max(1, segment.scale) - 1) * progress),
            focusPoint: center.interpolated(to: target, progress: progress)
        )
    }

    private func eased(_ value: Double) -> Double {
        let t = max(0, min(1, value))
        return t < 0.5
            ? 4 * t * t * t
            : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func clampedFocus(_ point: CGPoint, scale: Double) -> CGPoint {
        let halfWidth = sourceSize.width / (2 * scale)
        let halfHeight = sourceSize.height / (2 * scale)
        return CGPoint(
            x: min(sourceSize.width - halfWidth, max(halfWidth, point.x)),
            y: min(sourceSize.height - halfHeight, max(halfHeight, point.y))
        )
    }
}
