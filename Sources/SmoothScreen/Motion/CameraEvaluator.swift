import CoreGraphics
import Foundation

struct CameraState: Equatable {
    let scale: Double
    let focusPoint: CGPoint
}

struct CameraEvaluator {
    let segments: [ZoomSegment]
    let sourceSize: CGSize
    let cursorPath: CursorPath?
    var zoomOutDuration: Double
    var maximumConnectedGap = 2.75
    var connectedTravelFraction = 0.7
    var travelZoneFraction = 0.45
    var farTravelStart = 0.38
    var farTravelEnd = 0.58
    var cursorFollowSmoothingRadius = 0.2

    init(
        segments: [ZoomSegment],
        sourceSize: CGSize,
        cursorPath: CursorPath? = nil,
        zoomOutDuration: Double = 0.5
    ) {
        self.segments = segments.sorted { $0.startTime < $1.startTime }
        self.sourceSize = sourceSize
        self.cursorPath = cursorPath
        self.zoomOutDuration = zoomOutDuration
    }

    func state(at time: Double) -> CameraState {
        let baseState = undampedState(at: time, followsCursor: false)
        guard cursorPath != nil, cursorFollowSmoothingRadius > 0 else {
            return undampedState(at: time, followsCursor: true)
        }

        let sampleInterval = 1.0 / 60.0
        let sampleRadius = Int(ceil(cursorFollowSmoothingRadius / sampleInterval))
        var totalWeight = 0.0
        var scaleAdjustment = 0.0
        var focusAdjustmentX = 0.0
        var focusAdjustmentY = 0.0

        for offset in -sampleRadius...sampleRadius {
            let sampleTime = time + (Double(offset) * sampleInterval)
            guard sampleTime >= 0 else { continue }

            let distance = abs(Double(offset) * sampleInterval)
            let weight = max(
                0,
                1 - (distance / (cursorFollowSmoothingRadius + sampleInterval))
            )
            guard weight > 0 else { continue }

            let sampleBase = undampedState(at: sampleTime, followsCursor: false)
            let sampleFollowed = undampedState(at: sampleTime, followsCursor: true)
            totalWeight += weight
            scaleAdjustment += (sampleFollowed.scale - sampleBase.scale) * weight
            focusAdjustmentX += (
                sampleFollowed.focusPoint.x - sampleBase.focusPoint.x
            ) * weight
            focusAdjustmentY += (
                sampleFollowed.focusPoint.y - sampleBase.focusPoint.y
            ) * weight
        }

        guard totalWeight > 0 else { return baseState }
        let scale = max(1, baseState.scale + (scaleAdjustment / totalWeight))
        let focus = CGPoint(
            x: baseState.focusPoint.x + (focusAdjustmentX / totalWeight),
            y: baseState.focusPoint.y + (focusAdjustmentY / totalWeight)
        )
        return CameraState(scale: scale, focusPoint: clampedFocus(focus, scale: scale))
    }

    private func undampedState(at time: Double, followsCursor: Bool) -> CameraState {
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CameraState(scale: 1, focusPoint: .zero)
        }

        if let index = segments.firstIndex(where: { time >= $0.startTime && time <= $0.endTime }) {
            return state(
                in: segments[index],
                at: time,
                index: index,
                followsCursor: followsCursor
            )
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
                return followingCursor(
                    from: CameraState(scale: scale, focusPoint: focus),
                    anchor: focus,
                    at: time,
                    enabled: followsCursor
                )
            }
        }

        return CameraState(scale: 1, focusPoint: center)
    }

    private func state(
        in segment: ZoomSegment,
        at time: Double,
        index: Int,
        followsCursor: Bool
    ) -> CameraState {
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
        return followingCursor(
            from: baseState,
            anchor: target,
            at: time,
            enabled: followsCursor && segment.source == .automatic
        )
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

    private func followingCursor(
        from baseState: CameraState,
        anchor: CGPoint,
        at time: Double,
        enabled: Bool
    ) -> CameraState {
        guard
            enabled,
            baseState.scale > 1.001,
            let cursorFrame = cursorPath?.frame(at: time),
            cursorFrame.opacity > 0.001
        else { return baseState }

        let cursor = cursorFrame.position
        let normalizedTravel = hypot(
            (cursor.x - anchor.x) / sourceSize.width,
            (cursor.y - anchor.y) / sourceSize.height
        )
        let farProgress = eased(
            (normalizedTravel - farTravelStart) / max(0.001, farTravelEnd - farTravelStart)
        )
        let scale = 1 + ((baseState.scale - 1) * (1 - farProgress))
        let adjustedZoomProgress = (scale - 1) / max(0.001, baseState.scale - 1)
        var focus = center.interpolated(
            to: baseState.focusPoint,
            progress: adjustedZoomProgress
        )

        guard scale > 1.001 else {
            return CameraState(scale: 1, focusPoint: center)
        }

        let halfViewportWidth = sourceSize.width / (2 * scale)
        let halfViewportHeight = sourceSize.height / (2 * scale)
        let halfZoneWidth = halfViewportWidth * travelZoneFraction
        let halfZoneHeight = halfViewportHeight * travelZoneFraction

        if cursor.x < focus.x - halfZoneWidth {
            focus.x = cursor.x + halfZoneWidth
        } else if cursor.x > focus.x + halfZoneWidth {
            focus.x = cursor.x - halfZoneWidth
        }
        if cursor.y < focus.y - halfZoneHeight {
            focus.y = cursor.y + halfZoneHeight
        } else if cursor.y > focus.y + halfZoneHeight {
            focus.y = cursor.y - halfZoneHeight
        }

        return CameraState(scale: scale, focusPoint: clampedFocus(focus, scale: scale))
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

    private var center: CGPoint {
        CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
    }
}
