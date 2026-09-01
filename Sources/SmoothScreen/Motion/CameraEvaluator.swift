import CoreGraphics
import Foundation

struct CameraState: Equatable {
    let scale: Double
    let focusPoint: CGPoint
}

struct CameraEvaluator {
    let segments: [ZoomSegment]
    let sourceSize: CGSize
    var zoomOutDuration: Double
    var maximumConnectedGap = 2.75
    var connectedTravelFraction = 0.5

    init(
        segments: [ZoomSegment],
        sourceSize: CGSize,
        zoomOutDuration: Double = 0.5
    ) {
        self.segments = segments.sorted { $0.startTime < $1.startTime }
        self.sourceSize = sourceSize
        self.zoomOutDuration = zoomOutDuration
    }

    func state(at time: Double) -> CameraState {
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CameraState(scale: 1, focusPoint: .zero)
        }

        if let transition = overlappingTransition(at: time) {
            return transition
        }

        if let index = segments.firstIndex(where: { time >= $0.startTime && time <= $0.endTime }) {
            return state(in: segments[index], at: time, index: index)
        }

        if
            let previousIndex = segments.lastIndex(where: { $0.endTime < time }),
            previousIndex + 1 < segments.count
        {
            let previous = segments[previousIndex]
            let next = segments[previousIndex + 1]
            if time < next.startTime, canTravel(from: previous, to: next) {
                let duration = max(0.001, next.startTime - previous.endTime)
                let progress = eased((time - previous.endTime) / duration)
                let previousTarget = clampedFocus(
                    previous.focusPoint.cgPoint,
                    scale: max(1, previous.scale)
                )
                let nextTarget = clampedFocus(
                    next.focusPoint.cgPoint,
                    scale: max(1, next.scale)
                )
                let scale = max(1, previous.scale)
                    + ((max(1, next.scale) - max(1, previous.scale)) * progress)
                let focus = previousTarget.interpolated(to: nextTarget, progress: progress)
                return CameraState(scale: scale, focusPoint: focus)
            }
        }

        return CameraState(scale: 1, focusPoint: center)
    }

    private func overlappingTransition(at time: Double) -> CameraState? {
        guard segments.count > 1 else { return nil }

        for nextIndex in segments.indices.dropFirst().reversed() {
            let previous = segments[nextIndex - 1]
            let next = segments[nextIndex]
            guard next.startTime < previous.endTime else { continue }

            let transitionStart = previous.focusTime
            let transitionEnd = max(transitionStart + 0.001, next.focusTime)
            guard time >= transitionStart, time <= transitionEnd else { continue }

            let progress = eased((time - transitionStart) / (transitionEnd - transitionStart))
            let previousScale = max(1, previous.scale)
            let nextScale = max(1, next.scale)
            let scale = previousScale + ((nextScale - previousScale) * progress)
            let previousTarget = clampedFocus(previous.focusPoint.cgPoint, scale: previousScale)
            let nextTarget = clampedFocus(next.focusPoint.cgPoint, scale: nextScale)
            return CameraState(
                scale: scale,
                focusPoint: previousTarget.interpolated(to: nextTarget, progress: progress)
            )
        }

        return nil
    }

    private func state(in segment: ZoomSegment, at time: Double, index: Int) -> CameraState {
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        let connectsFromPrevious = index > 0 && canTravel(from: segments[index - 1], to: segment)
        let connectsToNext = index + 1 < segments.count && canTravel(from: segment, to: segments[index + 1])
        let progress: Double
        if time < segment.focusTime, !connectsFromPrevious {
            let duration = max(0.001, segment.focusTime - segment.startTime)
            progress = eased((time - segment.startTime) / duration)
        } else {
            let exitStart = max(segment.focusTime, segment.endTime - zoomOutDuration)
            if time <= exitStart || connectsToNext {
                progress = 1
            } else {
                let duration = max(0.001, segment.endTime - exitStart)
                progress = 1 - eased((time - exitStart) / duration)
            }
        }

        let target = clampedFocus(segment.focusPoint.cgPoint, scale: max(1, segment.scale))
        let baseState = CameraState(
            scale: 1 + ((max(1, segment.scale) - 1) * progress),
            focusPoint: center.interpolated(to: target, progress: progress)
        )
        return baseState
    }

    private func canTravel(from first: ZoomSegment, to second: ZoomSegment) -> Bool {
        guard first.source == .automatic, second.source == .automatic else { return false }
        let gap = second.startTime - first.endTime
        guard gap >= 0, gap <= maximumConnectedGap else { return false }

        let scale = max(1, min(first.scale, second.scale))
        let viewport = CGSize(width: sourceSize.width / scale, height: sourceSize.height / scale)
        let firstTarget = clampedFocus(first.focusPoint.cgPoint, scale: scale)
        let secondTarget = clampedFocus(second.focusPoint.cgPoint, scale: scale)
        return abs(secondTarget.x - firstTarget.x) <= viewport.width * connectedTravelFraction
            && abs(secondTarget.y - firstTarget.y) <= viewport.height * connectedTravelFraction
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
