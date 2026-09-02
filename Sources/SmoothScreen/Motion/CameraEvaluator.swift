import CoreGraphics
import Foundation

/// Cursor bitmap extents expressed as fractions of half the rendered viewport.
/// The camera uses these asymmetric margins to keep the entire arrow visible,
/// not just its hotspot.
struct CursorViewportInsets: Equatable {
    let left: Double
    let right: Double
    let top: Double
    let bottom: Double

    static let zero = CursorViewportInsets(left: 0, right: 0, top: 0, bottom: 0)

    func horizontalRange(
        halfExtent: Double,
        viewportFraction: Double
    ) -> ClosedRange<Double> {
        Self.allowedRange(
            halfExtent: halfExtent,
            leadingInset: left,
            trailingInset: right,
            viewportFraction: viewportFraction
        )
    }

    func verticalRange(
        halfExtent: Double,
        viewportFraction: Double
    ) -> ClosedRange<Double> {
        Self.allowedRange(
            halfExtent: halfExtent,
            leadingInset: top,
            trailingInset: bottom,
            viewportFraction: viewportFraction
        )
    }

    private static func allowedRange(
        halfExtent: Double,
        leadingInset: Double,
        trailingInset: Double,
        viewportFraction: Double
    ) -> ClosedRange<Double> {
        let bitmapLowerBound = -halfExtent * (1 - leadingInset)
        let bitmapUpperBound = halfExtent * (1 - trailingInset)
        guard bitmapLowerBound <= bitmapUpperBound else {
            let bestFit = (bitmapLowerBound + bitmapUpperBound) / 2
            return bestFit...bestFit
        }

        let fraction = max(0, min(1, viewportFraction))
        let lowerBound = max(bitmapLowerBound, -halfExtent * fraction)
        let upperBound = min(bitmapUpperBound, halfExtent * fraction)
        return lowerBound <= upperBound
            ? lowerBound...upperBound
            : bitmapLowerBound...bitmapUpperBound
    }
}

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
        cursorPath: CursorPath? = nil,
        cursorViewportInsets: CursorViewportInsets = .zero
    ) {
        trajectory = CameraTrajectory(
            segments: segments,
            sourceSize: sourceSize,
            duration: duration,
            cursorPath: cursorPath,
            cursorViewportInsets: cursorViewportInsets
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
        let travelZoneFraction = 0.65
        let cursorVisibilityOuterFraction = 1.0
        let cursorFollowDuration = 0.35
        let cursorFeedForwardRampDuration = 0.45
    }

    private struct Target {
        var state: CameraState
        var responseDuration: Double
        var segment: ZoomSegment?
        var cursorVisibilitySegment: ZoomSegment?
    }

    private struct CursorFollower {
        var segmentID: UUID?
        var anchor: CGPoint?

        mutating func adjust(
            _ target: Target,
            cursorPath: CursorPath?,
            at time: Double,
            sourceSize: CGSize,
            viewportInsets: CursorViewportInsets,
            configuration: Configuration
        ) -> Target {
            guard
                let segment = target.segment,
                segment.source == .automatic
            else {
                reset()
                return target
            }

            if segmentID != segment.id {
                segmentID = segment.id
                anchor = target.state.focusPoint
            }

            guard
                let cursorFrame = cursorPath?.frame(at: time),
                cursorFrame.opacity > 0
            else {
                guard let anchor else { return target }
                return adjustedTarget(
                    target,
                    anchor: anchor,
                    sourceSize: sourceSize,
                    configuration: configuration
                )
            }

            var targetAnchor = anchor ?? target.state.focusPoint
            let targetScale = max(1, target.state.scale)
            let halfWidth = sourceSize.width / (2 * targetScale)
            let halfHeight = sourceSize.height / (2 * targetScale)
            let horizontalDelta = cursorFrame.position.x - targetAnchor.x
            let verticalDelta = cursorFrame.position.y - targetAnchor.y
            let horizontalRange = viewportInsets.horizontalRange(
                halfExtent: halfWidth,
                viewportFraction: configuration.travelZoneFraction
            )
            let verticalRange = viewportInsets.verticalRange(
                halfExtent: halfHeight,
                viewportFraction: configuration.travelZoneFraction
            )
            targetAnchor.x = cursorFrame.position.x
                - horizontalDelta.clamped(to: horizontalRange)
            targetAnchor.y = cursorFrame.position.y
                - verticalDelta.clamped(to: verticalRange)

            targetAnchor = CameraTrajectory.clampedFocus(
                targetAnchor,
                sourceSize: sourceSize,
                scale: targetScale
            )
            anchor = targetAnchor

            return adjustedTarget(
                target,
                anchor: targetAnchor,
                sourceSize: sourceSize,
                configuration: configuration
            )
        }

        private func adjustedTarget(
            _ target: Target,
            anchor: CGPoint,
            sourceSize: CGSize,
            configuration: Configuration
        ) -> Target {
            let scale = max(1, target.state.scale)
            let focus = CameraTrajectory.clampedFocus(
                anchor,
                sourceSize: sourceSize,
                scale: scale
            )
            var adjusted = target
            adjusted.state = CameraState(scale: scale, focusPoint: focus)
            if focus.distance(to: target.state.focusPoint) > 0.5 {
                adjusted.responseDuration = min(
                    adjusted.responseDuration,
                    configuration.cursorFollowDuration
                )
            }
            return adjusted
        }

        mutating func reset() {
            segmentID = nil
            anchor = nil
        }
    }

    private struct CursorVisibilityGuard {
        var segmentID: UUID?
        var previousCursorPosition: CGPoint?
        var previousFocusPoint: CGPoint?
        var previousPose: SpringPose?
        var horizontalFollowAmount = 0.0
        var verticalFollowAmount = 0.0

        mutating func adjust(
            _ spring: inout SpringVector,
            target: Target,
            cursorPath: CursorPath?,
            at time: Double,
            sourceSize: CGSize,
            viewportInsets: CursorViewportInsets,
            configuration: Configuration
        ) {
            guard
                let segment = target.cursorVisibilitySegment,
                segment.source == .automatic,
                let cursorFrame = cursorPath?.frame(at: time),
                cursorFrame.opacity > 0
            else {
                reset()
                return
            }

            if segmentID != segment.id {
                segmentID = segment.id
                previousCursorPosition = nil
                previousFocusPoint = nil
                previousPose = nil
                horizontalFollowAmount = 0
                verticalFollowAmount = 0
            }

            let camera = spring.value.cameraState(sourceSize: sourceSize)
            let halfWidth = sourceSize.width / (2 * camera.scale)
            let halfHeight = sourceSize.height / (2 * camera.scale)
            let horizontalDelta = cursorFrame.position.x - camera.focusPoint.x
            let verticalDelta = cursorFrame.position.y - camera.focusPoint.y
            let horizontalOuterRange = viewportInsets.horizontalRange(
                halfExtent: halfWidth,
                viewportFraction: configuration.cursorVisibilityOuterFraction
            )
            let verticalOuterRange = viewportInsets.verticalRange(
                halfExtent: halfHeight,
                viewportFraction: configuration.cursorVisibilityOuterFraction
            )
            let horizontalTravelRange = viewportInsets.horizontalRange(
                halfExtent: halfWidth,
                viewportFraction: configuration.travelZoneFraction
            )
            let verticalTravelRange = viewportInsets.verticalRange(
                halfExtent: halfHeight,
                viewportFraction: configuration.travelZoneFraction
            )
            let horizontalFocusRange = Double(halfWidth)...Double(sourceSize.width - halfWidth)
            let verticalFocusRange = Double(halfHeight)...Double(sourceSize.height - halfHeight)
            let horizontal = Self.adjustedAxis(
                cursor: Double(cursorFrame.position.x),
                springFocus: Double(camera.focusPoint.x),
                springDelta: Double(horizontalDelta),
                previousCursor: previousCursorPosition.map { Double($0.x) },
                previousFocus: previousFocusPoint.map { Double($0.x) },
                travelRange: horizontalTravelRange,
                outerRange: horizontalOuterRange,
                focusRange: horizontalFocusRange,
                previousFollowAmount: horizontalFollowAmount,
                deltaTime: 1 / configuration.sampleRate,
                followRampDuration: configuration.cursorFeedForwardRampDuration
            )
            let vertical = Self.adjustedAxis(
                cursor: Double(cursorFrame.position.y),
                springFocus: Double(camera.focusPoint.y),
                springDelta: Double(verticalDelta),
                previousCursor: previousCursorPosition.map { Double($0.y) },
                previousFocus: previousFocusPoint.map { Double($0.y) },
                travelRange: verticalTravelRange,
                outerRange: verticalOuterRange,
                focusRange: verticalFocusRange,
                previousFollowAmount: verticalFollowAmount,
                deltaTime: 1 / configuration.sampleRate,
                followRampDuration: configuration.cursorFeedForwardRampDuration
            )
            horizontalFollowAmount = horizontal.followAmount
            verticalFollowAmount = vertical.followAmount

            let constrainedFocus = CameraTrajectory.clampedFocus(
                CGPoint(x: CGFloat(horizontal.focus), y: CGFloat(vertical.focus)),
                sourceSize: sourceSize,
                scale: camera.scale
            )
            spring.constrainPan(
                to: constrainedFocus,
                sourceSize: sourceSize,
                previousPose: previousPose,
                deltaTime: 1 / configuration.sampleRate,
                matchHorizontalVelocity: horizontal.didAdjust,
                matchVerticalVelocity: vertical.didAdjust
            )
            previousCursorPosition = cursorFrame.position
            previousFocusPoint = constrainedFocus
            previousPose = spring.value
        }

        private static func adjustedAxis(
            cursor: Double,
            springFocus: Double,
            springDelta: Double,
            previousCursor: Double?,
            previousFocus: Double?,
            travelRange: ClosedRange<Double>,
            outerRange: ClosedRange<Double>,
            focusRange: ClosedRange<Double>,
            previousFollowAmount: Double,
            deltaTime: Double,
            followRampDuration: Double
        ) -> (focus: Double, didAdjust: Bool, followAmount: Double) {
            let followProgress = Self.followProgress(
                for: springDelta,
                travelRange: travelRange,
                outerRange: outerRange
            )
            var candidateFocus = springFocus
            var followAmount = 0.0
            if
                followProgress > 0,
                let previousCursor,
                let previousFocus,
                Self.isMovingOutward(
                    cursorStep: cursor - previousCursor,
                    cursorDelta: springDelta,
                    travelRange: travelRange
                )
            {
                let cursorStep = cursor - previousCursor
                let translatedFocus = previousFocus + (cursor - previousCursor)
                let maximumFollowChange = deltaTime / max(deltaTime, followRampDuration)
                followAmount = previousFollowAmount + (followProgress - previousFollowAmount)
                    .clamped(to: -maximumFollowChange...maximumFollowChange)
                let travelBlend = Self.smoothStep(followAmount)
                let availablePan = cursorStep > 0
                    ? focusRange.upperBound - springFocus
                    : springFocus - focusRange.lowerBound
                let taperDistance = max(1, (outerRange.upperBound - outerRange.lowerBound) * 0.18)
                let boundaryBlend = Self.smoothStep(
                    (availablePan / taperDistance).clamped(to: 0...1)
                )
                let blend = travelBlend * boundaryBlend
                candidateFocus += (translatedFocus - candidateFocus) * blend
            }

            // An instantaneous cursor jump can still outrun the progressive
            // feed-forward above. Correct only the minimum distance needed to
            // keep the cursor visible; ordinary motion never reaches this rail.
            let candidateDelta = cursor - candidateFocus
            let constrainedDelta = candidateDelta.clamped(to: outerRange)
            if constrainedDelta != candidateDelta {
                candidateFocus = cursor - constrainedDelta
            }
            return (
                candidateFocus,
                abs(candidateFocus - springFocus) > 0.000_001,
                followAmount
            )
        }

        private static func isMovingOutward(
            cursorStep: Double,
            cursorDelta: Double,
            travelRange: ClosedRange<Double>
        ) -> Bool {
            (cursorDelta < travelRange.lowerBound && cursorStep < -0.000_001)
                || (cursorDelta > travelRange.upperBound && cursorStep > 0.000_001)
        }

        private static func smoothStep(_ value: Double) -> Double {
            value * value * (3 - (2 * value))
        }

        private static func followProgress(
            for delta: Double,
            travelRange: ClosedRange<Double>,
            outerRange: ClosedRange<Double>
        ) -> Double {
            if delta < travelRange.lowerBound {
                let span = travelRange.lowerBound - outerRange.lowerBound
                guard span > 0.000_001 else { return 1 }
                return ((travelRange.lowerBound - delta) / span).clamped(to: 0...1)
            }
            if delta > travelRange.upperBound {
                let span = outerRange.upperBound - travelRange.upperBound
                guard span > 0.000_001 else { return 1 }
                return ((delta - travelRange.upperBound) / span).clamped(to: 0...1)
            }
            return 0
        }

        private mutating func reset() {
            segmentID = nil
            previousCursorPosition = nil
            previousFocusPoint = nil
            previousPose = nil
            horizontalFollowAmount = 0
            verticalFollowAmount = 0
        }
    }

    private let sourceSize: CGSize
    private let sampleInterval: Double
    private let samples: [SpringPose]
    private let configuration: Configuration
    private let segments: [ZoomSegment]
    private let cursorPath: CursorPath?
    private let cursorViewportInsets: CursorViewportInsets

    init(
        segments: [ZoomSegment],
        sourceSize: CGSize,
        duration: Double?,
        cursorPath: CursorPath?,
        cursorViewportInsets: CursorViewportInsets
    ) {
        self.sourceSize = sourceSize
        let configuration = Configuration()
        self.configuration = configuration
        self.cursorPath = cursorPath
        self.cursorViewportInsets = cursorViewportInsets
        sampleInterval = 1 / configuration.sampleRate

        let sortedSegments = segments.sorted {
            if $0.startTime == $1.startTime {
                return $0.focusTime < $1.focusTime
            }
            return $0.startTime < $1.startTime
        }
        self.segments = sortedSegments

        guard sourceSize.width > 0, sourceSize.height > 0 else {
            samples = [.overview]
            return
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
        var cursorVisibilityGuard = CursorVisibilityGuard()
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
                cursorPath: cursorPath,
                at: time,
                sourceSize: sourceSize,
                viewportInsets: cursorViewportInsets,
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
            // The soft travel band progressively borrows the cursor's velocity.
            // The outer edge remains a last-resort visibility constraint.
            cursorVisibilityGuard.adjust(
                &spring,
                target: target,
                cursorPath: cursorPath,
                at: time,
                sourceSize: sourceSize,
                viewportInsets: cursorViewportInsets,
                configuration: configuration
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
        let state = pose.cameraState(sourceSize: sourceSize)
        // Render requests can fall between trajectory samples, so enforce the
        // same safety rail at the exact presentation time as the cursor overlay.
        guard
            Self.target(
                at: time,
                segments: segments,
                sourceSize: sourceSize,
                configuration: configuration
            ).cursorVisibilitySegment?.source == .automatic,
            let cursorFrame = cursorPath?.frame(at: time),
            cursorFrame.opacity > 0
        else { return state }

        return Self.keepingVisible(
            cursorFrame.position,
            in: state,
            sourceSize: sourceSize,
            viewportFraction: 1,
            viewportInsets: cursorViewportInsets
        )
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
            segment: nil,
            cursorVisibilitySegment: nil
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
                    segment: current,
                    cursorVisibilitySegment: current
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
                    segment: next,
                    cursorVisibilitySegment: next
                )
            }

            return Target(
                state: overview.state,
                responseDuration: exitDuration,
                segment: nil,
                cursorVisibilitySegment: current
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
                segment: next,
                cursorVisibilitySegment: next
            )
        }

        let exitDuration = current.transitionDuration
            ?? configuration.defaultTransitionDuration
        if time <= current.endTime + exitDuration {
            return Target(
                state: overview.state,
                responseDuration: exitDuration,
                segment: nil,
                cursorVisibilitySegment: current
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

    fileprivate static func clampedFocus(
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

    fileprivate static func keepingVisible(
        _ point: CGPoint,
        in camera: CameraState,
        sourceSize: CGSize,
        viewportFraction: Double,
        viewportInsets: CursorViewportInsets
    ) -> CameraState {
        let halfWidth = sourceSize.width / (2 * camera.scale)
        let halfHeight = sourceSize.height / (2 * camera.scale)
        var focus = camera.focusPoint

        let horizontalDelta = point.x - focus.x
        let horizontalRange = viewportInsets.horizontalRange(
            halfExtent: halfWidth,
            viewportFraction: viewportFraction
        )
        focus.x = point.x - horizontalDelta.clamped(to: horizontalRange)
        let verticalDelta = point.y - focus.y
        let verticalRange = viewportInsets.verticalRange(
            halfExtent: halfHeight,
            viewportFraction: viewportFraction
        )
        focus.y = point.y - verticalDelta.clamped(to: verticalRange)

        return CameraState(
            scale: camera.scale,
            focusPoint: clampedFocus(focus, sourceSize: sourceSize, scale: camera.scale)
        )
    }
}

/// A bounded camera pose. Pan is represented as an angle and projected through
/// sine, which reaches the source edge with a finite target while naturally
/// reducing visible velocity there.
private struct SpringPose {
    fileprivate static let maximumPan = Double.pi / 2

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
        horizontalPan = asin((normalizedHorizontal / limit).clamped(to: -1...1))
        verticalPan = asin((normalizedVertical / limit).clamped(to: -1...1))
    }

    func cameraState(sourceSize: CGSize) -> CameraState {
        let scale = max(1, exp(logScale))
        let limit = (scale - 1) / 2
        let normalizedHorizontal = limit * sin(
            horizontalPan.clamped(to: -Self.maximumPan...Self.maximumPan)
        )
        let normalizedVertical = limit * sin(
            verticalPan.clamped(to: -Self.maximumPan...Self.maximumPan)
        )
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
}

private struct SpringVector {
    var value: SpringPose
    var velocity: SpringPose

    mutating func advance(
        toward target: SpringPose,
        omega: Double,
        deltaTime: Double
    ) {
        let horizontal = Self.boundedPan(Self.advance(
            value: value.horizontalPan,
            velocity: velocity.horizontalPan,
            target: target.horizontalPan,
            omega: omega,
            deltaTime: deltaTime
        ))
        let vertical = Self.boundedPan(Self.advance(
            value: value.verticalPan,
            velocity: velocity.verticalPan,
            target: target.verticalPan,
            omega: omega,
            deltaTime: deltaTime
        ))
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

    mutating func constrainPan(
        to focusPoint: CGPoint,
        sourceSize: CGSize,
        previousPose: SpringPose?,
        deltaTime: Double,
        matchHorizontalVelocity: Bool,
        matchVerticalVelocity: Bool
    ) {
        let camera = value.cameraState(sourceSize: sourceSize)
        let constrained = SpringPose(
            cameraState: CameraState(scale: camera.scale, focusPoint: focusPoint),
            sourceSize: sourceSize
        )
        let horizontalCorrection = constrained.horizontalPan - value.horizontalPan
        let verticalCorrection = constrained.verticalPan - value.verticalPan
        value.horizontalPan = constrained.horizontalPan
        value.verticalPan = constrained.verticalPan
        if matchHorizontalVelocity, let previousPose, deltaTime > 0 {
            velocity.horizontalPan = (constrained.horizontalPan - previousPose.horizontalPan)
                / deltaTime
        } else if horizontalCorrection * velocity.horizontalPan < 0 {
            velocity.horizontalPan = 0
        }
        if matchVerticalVelocity, let previousPose, deltaTime > 0 {
            velocity.verticalPan = (constrained.verticalPan - previousPose.verticalPan)
                / deltaTime
        } else if verticalCorrection * velocity.verticalPan < 0 {
            velocity.verticalPan = 0
        }
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

    private static func boundedPan(
        _ result: (value: Double, velocity: Double)
    ) -> (value: Double, velocity: Double) {
        let limit = SpringPose.maximumPan
        if result.value < -limit {
            return (-limit, result.velocity < 0 ? 0 : result.velocity)
        }
        if result.value > limit {
            return (limit, result.velocity > 0 ? 0 : result.velocity)
        }
        return result
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<Double>) -> CGFloat {
        CGFloat(Double(self).clamped(to: range))
    }
}
