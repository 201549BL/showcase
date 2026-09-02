import CoreGraphics
import Foundation

struct CameraState: Equatable {
    let scale: Double
    let focusPoint: CGPoint
}

/// An immutable, random-access camera track.
///
/// AVFoundation may render frames concurrently or out of order, so the spring is
/// simulated once during initialization instead of carrying mutable state between
/// `state(at:)` calls. Pan and zoom are integrated as one pose and every retarget
/// inherits the existing velocity.
struct CameraEvaluator {
    private let trajectory: CameraTrajectory

    init(
        segments: [ZoomSegment],
        sourceSize: CGSize,
        duration: Double? = nil,
        cursorPath: CursorPath? = nil
    ) {
        trajectory = CameraTrajectory(
            segments: segments,
            sourceSize: sourceSize,
            duration: duration,
            cursorPath: cursorPath
        )
    }

    func state(at time: Double) -> CameraState {
        trajectory.state(at: time)
    }
}

private struct CameraTrajectory {
    private struct Configuration {
        let sampleRate = 120.0
        let defaultTransitionDuration = 0.5
        let minimumTransitionDuration = 0.18
        let springSettlingConstant = 4.75
        let maximumConnectedGap = 2.75
        let connectedTravelFraction = 0.5
        let cursorLookAhead = 0.12
        let travelZoneFraction = 0.72
        let travelSettleFraction = 0.55
        let distantTravelPadding = 0.2
        let distantTravelHold = 0.55
        let cursorFollowDuration = 0.6
    }

    private struct Target {
        var state: CameraState
        var responseDuration: Double
        var segment: ZoomSegment?
    }

    private struct CursorFollower {
        var segmentID: UUID?
        var anchor: CGPoint?
        var widenedScale: Double?
        var keepWideUntil = 0.0

        mutating func adjust(
            _ target: Target,
            currentState: CameraState,
            cursorPath: CursorPath?,
            at time: Double,
            sourceSize: CGSize,
            configuration: Configuration
        ) -> Target {
            guard
                let segment = target.segment,
                segment.source == .automatic,
                let cursorPath,
                let cursor = cursorPath.frame(at: time + configuration.cursorLookAhead)?.position
            else {
                reset()
                return target
            }

            if segmentID != segment.id {
                segmentID = segment.id
                anchor = target.state.focusPoint
                widenedScale = nil
                keepWideUntil = 0
            }

            var adjusted = target
            let requestedScale = max(1, target.state.scale)
            let currentScale = max(1, currentState.scale)
            let currentHalfWidth = sourceSize.width / (2 * currentScale)
            let currentHalfHeight = sourceSize.height / (2 * currentScale)
            let isDistant = abs(cursor.x - currentState.focusPoint.x) > currentHalfWidth * 0.92
                || abs(cursor.y - currentState.focusPoint.y) > currentHalfHeight * 0.92

            if isDistant {
                let paddedWidth = abs(cursor.x - currentState.focusPoint.x)
                    + sourceSize.width * configuration.distantTravelPadding
                let paddedHeight = abs(cursor.y - currentState.focusPoint.y)
                    + sourceSize.height * configuration.distantTravelPadding
                let fittingScale = min(
                    requestedScale,
                    sourceSize.width / max(1, paddedWidth),
                    sourceSize.height / max(1, paddedHeight)
                )
                widenedScale = min(
                    widenedScale ?? requestedScale,
                    max(1.08, fittingScale)
                )
                keepWideUntil = time + configuration.distantTravelHold
            } else if time >= keepWideUntil {
                widenedScale = nil
            }

            let targetScale = widenedScale ?? requestedScale
            var targetAnchor = anchor ?? target.state.focusPoint
            let halfWidth = sourceSize.width / (2 * targetScale)
            let halfHeight = sourceSize.height / (2 * targetScale)
            let horizontalDelta = cursor.x - targetAnchor.x
            let verticalDelta = cursor.y - targetAnchor.y
            var didMove = false

            if abs(horizontalDelta) > halfWidth * configuration.travelZoneFraction {
                targetAnchor.x = cursor.x
                    - (horizontalDelta >= 0 ? 1 : -1)
                    * halfWidth * configuration.travelSettleFraction
                didMove = true
            }
            if abs(verticalDelta) > halfHeight * configuration.travelZoneFraction {
                targetAnchor.y = cursor.y
                    - (verticalDelta >= 0 ? 1 : -1)
                    * halfHeight * configuration.travelSettleFraction
                didMove = true
            }

            targetAnchor = CameraTrajectory.clampedFocus(
                targetAnchor,
                sourceSize: sourceSize,
                scale: targetScale
            )
            anchor = targetAnchor
            adjusted.state = CameraState(scale: targetScale, focusPoint: targetAnchor)
            if didMove || widenedScale != nil || abs(targetScale - requestedScale) > 0.001 {
                adjusted.responseDuration = max(
                    adjusted.responseDuration,
                    configuration.cursorFollowDuration
                )
            }
            return adjusted
        }

        mutating func reset() {
            segmentID = nil
            anchor = nil
            widenedScale = nil
            keepWideUntil = 0
        }
    }

    private let sourceSize: CGSize
    private let sampleInterval: Double
    private let samples: [SpringPose]

    init(
        segments: [ZoomSegment],
        sourceSize: CGSize,
        duration: Double?,
        cursorPath: CursorPath?
    ) {
        self.sourceSize = sourceSize
        let configuration = Configuration()
        sampleInterval = 1 / configuration.sampleRate

        guard sourceSize.width > 0, sourceSize.height > 0 else {
            samples = [.overview]
            return
        }

        let sortedSegments = segments.sorted {
            if $0.startTime == $1.startTime {
                return $0.focusTime < $1.focusTime
            }
            return $0.startTime < $1.startTime
        }
        let lastEnd = sortedSegments.map(\.endTime).max() ?? 0
        let longestTransition = sortedSegments
            .compactMap(\.transitionDuration)
            .max() ?? configuration.defaultTransitionDuration
        let requestedDuration = max(0, duration ?? lastEnd)
        let settlingTail = max(1.5, longestTransition * 3)
        let trajectoryDuration = max(requestedDuration, lastEnd) + settlingTail
        let sampleCount = max(1, Int(ceil(trajectoryDuration / sampleInterval)))

        var spring = SpringVector(value: .overview, velocity: .zero)
        var cursorFollower = CursorFollower()
        var builtSamples: [SpringPose] = []
        builtSamples.reserveCapacity(sampleCount + 1)
        builtSamples.append(spring.value)

        for sampleIndex in 1...sampleCount {
            let time = Double(sampleIndex) * sampleInterval
            let baseTarget = Self.target(
                at: time,
                segments: sortedSegments,
                sourceSize: sourceSize,
                configuration: configuration
            )
            let target = cursorFollower.adjust(
                baseTarget,
                currentState: spring.value.cameraState(sourceSize: sourceSize),
                cursorPath: cursorPath,
                at: time,
                sourceSize: sourceSize,
                configuration: configuration
            )
            let responseDuration = max(
                configuration.minimumTransitionDuration,
                target.responseDuration
            )
            let omega = configuration.springSettlingConstant / responseDuration
            spring.advance(
                toward: SpringPose(cameraState: target.state, sourceSize: sourceSize),
                omega: omega,
                deltaTime: sampleInterval
            )
            builtSamples.append(spring.value)
        }

        samples = builtSamples
    }

    func state(at requestedTime: Double) -> CameraState {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CameraState(scale: 1, focusPoint: .zero)
        }

        let time = max(0, requestedTime)
        let exactIndex = time / sampleInterval
        let lowerIndex = min(samples.count - 1, Int(floor(exactIndex)))
        let upperIndex = min(samples.count - 1, lowerIndex + 1)
        let fraction = max(0, min(1, exactIndex - Double(lowerIndex)))
        let pose = samples[lowerIndex].interpolated(
            to: samples[upperIndex],
            progress: fraction
        )
        return pose.cameraState(sourceSize: sourceSize)
    }

    private static func target(
        at time: Double,
        segments: [ZoomSegment],
        sourceSize: CGSize,
        configuration: Configuration
    ) -> Target {
        let overview = Target(
            state: CameraState(
                scale: 1,
                focusPoint: CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
            ),
            responseDuration: configuration.defaultTransitionDuration,
            segment: nil
        )
        guard !segments.isEmpty else { return overview }

        guard let currentIndex = latestStartedIndex(in: segments, at: time) else {
            return overview
        }
        let current = segments[currentIndex]
        let nextIndex = segments.index(after: currentIndex)
        let next = nextIndex < segments.endIndex ? segments[nextIndex] : nil

        if time <= current.endTime {
            let exitDuration = current.transitionDuration
                ?? configuration.defaultTransitionDuration
            let exitStart = max(current.focusTime, current.endTime - exitDuration)

            if time < exitStart {
                return Target(
                    state: clampedState(for: current, sourceSize: sourceSize),
                    responseDuration: max(
                        configuration.minimumTransitionDuration,
                        current.focusTime - current.startTime
                    ),
                    segment: current
                )
            }

            if let next, canTravel(
                from: current,
                to: next,
                sourceSize: sourceSize,
                configuration: configuration
            ) {
                return Target(
                    state: clampedState(for: next, sourceSize: sourceSize),
                    responseDuration: max(
                        configuration.minimumTransitionDuration,
                        next.startTime - exitStart
                    ),
                    segment: next
                )
            }

            return Target(
                state: overview.state,
                responseDuration: exitDuration,
                segment: nil
            )
        }

        if let next, canTravel(
            from: current,
            to: next,
            sourceSize: sourceSize,
            configuration: configuration
        ) {
            return Target(
                state: clampedState(for: next, sourceSize: sourceSize),
                responseDuration: max(
                    configuration.minimumTransitionDuration,
                    next.startTime - current.endTime
                ),
                segment: next
            )
        }

        return overview
    }

    private static func latestStartedIndex(
        in segments: [ZoomSegment],
        at time: Double
    ) -> Int? {
        var lowerBound = 0
        var upperBound = segments.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if segments[middle].startTime <= time {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound > 0 ? lowerBound - 1 : nil
    }

    private static func canTravel(
        from first: ZoomSegment,
        to second: ZoomSegment,
        sourceSize: CGSize,
        configuration: Configuration
    ) -> Bool {
        guard first.source == .automatic, second.source == .automatic else { return false }
        let gap = second.startTime - first.endTime
        guard gap >= 0, gap <= configuration.maximumConnectedGap else { return false }

        let scale = max(1, min(first.scale, second.scale))
        let viewport = CGSize(width: sourceSize.width / scale, height: sourceSize.height / scale)
        let firstTarget = clampedFocus(first.focusPoint.cgPoint, sourceSize: sourceSize, scale: scale)
        let secondTarget = clampedFocus(second.focusPoint.cgPoint, sourceSize: sourceSize, scale: scale)
        return abs(secondTarget.x - firstTarget.x)
            <= viewport.width * configuration.connectedTravelFraction
            && abs(secondTarget.y - firstTarget.y)
            <= viewport.height * configuration.connectedTravelFraction
    }

    private static func clampedState(
        for segment: ZoomSegment,
        sourceSize: CGSize
    ) -> CameraState {
        let scale = max(1, segment.scale)
        return CameraState(
            scale: scale,
            focusPoint: clampedFocus(
                segment.focusPoint.cgPoint,
                sourceSize: sourceSize,
                scale: scale
            )
        )
    }

    private static func clampedFocus(
        _ point: CGPoint,
        sourceSize: CGSize,
        scale: Double
    ) -> CGPoint {
        let halfWidth = sourceSize.width / (2 * scale)
        let halfHeight = sourceSize.height / (2 * scale)
        return CGPoint(
            x: min(sourceSize.width - halfWidth, max(halfWidth, point.x)),
            y: min(sourceSize.height - halfHeight, max(halfHeight, point.y))
        )
    }
}

/// A bounded camera pose. The unbounded pan parameters are mapped through tanh,
/// which guarantees the sampled viewport never exposes pixels beyond the source.
private struct SpringPose {
    var horizontalPan: Double
    var verticalPan: Double
    var logScale: Double

    static let overview = SpringPose(horizontalPan: 0, verticalPan: 0, logScale: 0)
    static let zero = overview

    init(horizontalPan: Double, verticalPan: Double, logScale: Double) {
        self.horizontalPan = horizontalPan
        self.verticalPan = verticalPan
        self.logScale = logScale
    }

    init(cameraState: CameraState, sourceSize: CGSize) {
        let scale = max(1, cameraState.scale)
        logScale = log(scale)
        let limit = (scale - 1) / 2
        guard limit > 0.000_001 else {
            horizontalPan = 0
            verticalPan = 0
            return
        }

        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        let normalizedHorizontal = scale
            * (center.x - cameraState.focusPoint.x)
            / sourceSize.width
        let normalizedVertical = scale
            * (center.y - cameraState.focusPoint.y)
            / sourceSize.height
        horizontalPan = Self.inverseBoundedPan(normalizedHorizontal / limit)
        verticalPan = Self.inverseBoundedPan(normalizedVertical / limit)
    }

    func cameraState(sourceSize: CGSize) -> CameraState {
        let scale = max(1, exp(logScale))
        let limit = (scale - 1) / 2
        let normalizedHorizontal = limit * tanh(horizontalPan)
        let normalizedVertical = limit * tanh(verticalPan)
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        return CameraState(
            scale: scale,
            focusPoint: CGPoint(
                x: center.x - (normalizedHorizontal * sourceSize.width / scale),
                y: center.y - (normalizedVertical * sourceSize.height / scale)
            )
        )
    }

    func interpolated(to other: SpringPose, progress: Double) -> SpringPose {
        SpringPose(
            horizontalPan: horizontalPan + (other.horizontalPan - horizontalPan) * progress,
            verticalPan: verticalPan + (other.verticalPan - verticalPan) * progress,
            logScale: logScale + (other.logScale - logScale) * progress
        )
    }

    private static func inverseBoundedPan(_ value: Double) -> Double {
        let bounded = max(-0.999_9, min(0.999_9, value))
        return 0.5 * log((1 + bounded) / (1 - bounded))
    }
}

private struct SpringVector {
    var value: SpringPose
    var velocity: SpringPose

    mutating func advance(
        toward target: SpringPose,
        omega: Double,
        deltaTime: Double
    ) {
        let horizontal = Self.advance(
            value: value.horizontalPan,
            velocity: velocity.horizontalPan,
            target: target.horizontalPan,
            omega: omega,
            deltaTime: deltaTime
        )
        let vertical = Self.advance(
            value: value.verticalPan,
            velocity: velocity.verticalPan,
            target: target.verticalPan,
            omega: omega,
            deltaTime: deltaTime
        )
        let zoom = Self.advance(
            value: value.logScale,
            velocity: velocity.logScale,
            target: target.logScale,
            omega: omega,
            deltaTime: deltaTime
        )
        value = SpringPose(
            horizontalPan: horizontal.value,
            verticalPan: vertical.value,
            logScale: zoom.value
        )
        velocity = SpringPose(
            horizontalPan: horizontal.velocity,
            verticalPan: vertical.velocity,
            logScale: zoom.velocity
        )
    }

    private static func advance(
        value: Double,
        velocity: Double,
        target: Double,
        omega: Double,
        deltaTime: Double
    ) -> (value: Double, velocity: Double) {
        let offset = value - target
        let coefficient = velocity + omega * offset
        let decay = exp(-omega * deltaTime)
        return (
            target + (offset + coefficient * deltaTime) * decay,
            (velocity - omega * coefficient * deltaTime) * decay
        )
    }
}
