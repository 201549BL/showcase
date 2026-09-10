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
        cursorViewportInsets: CursorViewportInsets = .zero,
        motionStyle: ZoomBehaviorSettings.MotionStyle = .focused
    ) {
        trajectory = CameraTrajectory(
            segments: segments,
            sourceSize: sourceSize,
            duration: duration,
            cursorPath: cursorPath,
            cursorViewportInsets: cursorViewportInsets,
            motionStyle: motionStyle
        )
    }

    func state(at time: Double) -> CameraState {
        trajectory.state(at: time)
    }
}

private struct CameraTrajectory {
    private struct Configuration {
        let motionStyle: ZoomBehaviorSettings.MotionStyle
        let sampleRate = 120.0
        let defaultTransitionDuration = 0.5
        let minimumTransitionDuration = 0.18
        let cursorIntentRestDuration = 0.12
        let cursorVisibilityOuterFraction = 1.0

        func cursorFollowActivationFraction(for segment: ZoomSegment) -> Double {
            min(0.98, segment.resolvedCursorBoundaryFraction + 0.07)
        }

        var springSettlingConstant: Double {
            switch motionStyle {
            case .focused: return 4.75
            case .smooth: return 3.6
            }
        }

        func cursorIntentTakeoverDuration(for scale: Double) -> Double {
            switch motionStyle {
            case .focused: return scale >= 1.9 ? 0.08 : 0.12
            case .smooth: return 0.2
            }
        }

        func cursorFollowDuration(for scale: Double) -> Double {
            switch motionStyle {
            case .focused: return scale >= 1.9 ? 0.28 : 0.35
            case .smooth: return 0.55
            }
        }

        func cursorReframeDuration(for scale: Double, movementDuration: Double) -> Double {
            switch motionStyle {
            case .focused:
                let minimum = scale >= 1.9 ? 0.6 : 0.65
                return min(1.4, max(minimum, movementDuration * 1.5))
            case .smooth:
                return min(1.6, max(0.75, movementDuration * 1.7))
            }
        }

        func authoredReframeDuration(for scale: Double) -> Double {
            switch motionStyle {
            case .focused: return scale >= 1.9 ? 0.42 : 0.5
            case .smooth: return 0.75
            }
        }

        func cursorFeedForwardRampDuration(for scale: Double) -> Double {
            switch motionStyle {
            case .focused: return scale >= 1.9 ? 0.3 : 0.45
            case .smooth: return 0.7
            }
        }
    }

    private struct Target {
        var state: CameraState
        var responseDuration: Double
        var segment: ZoomSegment?
        var cursorVisibilitySegment: ZoomSegment?
        var cursorSteeringPosition: CGPoint? = nil
        var usesDeliberateReframe = false
        var authoredReframeID: UUID? = nil
    }

    private struct CursorFollower {
        private struct AxisIntentGate {
            private enum Phase {
                case quiet
                case takeover
                case tracking
            }

            private let movementEpsilon = 0.000_001

            private var phase = Phase.quiet
            private var isInitialized = false
            private var previousActual = 0.0
            private var previousRaw = 0.0
            private var quietReference = 0.0
            private var heldSteering = 0.0
            private var negativeSlop = 0.0
            private var positiveSlop = 0.0
            private var takeoverOrigin = 0.0
            private var takeoverStart = 0.0
            private var stationaryDuration = 0.0

            mutating func position(
                for actual: Double,
                rawPosition: Double,
                at time: Double,
                negativeSlop currentNegativeSlop: Double,
                positiveSlop currentPositiveSlop: Double,
                isOutsideSafetyRange: Bool,
                deltaTime: Double,
                takeoverDuration: Double,
                restDuration: Double
            ) -> Double {
                guard isInitialized else {
                    armQuiet(
                        at: actual,
                        negativeSlop: currentNegativeSlop,
                        positiveSlop: currentPositiveSlop
                    )
                    previousActual = actual
                    previousRaw = rawPosition
                    isInitialized = true
                    return actual
                }

                let rawCursorStep = rawPosition - previousRaw
                let isStationary = abs(rawCursorStep) <= movementEpsilon
                previousActual = actual
                previousRaw = rawPosition

                if isOutsideSafetyRange {
                    phase = .tracking
                    heldSteering = actual
                    stationaryDuration = 0
                    return actual
                }

                switch phase {
                case .quiet:
                    let displacement = actual - quietReference
                    guard displacement > positiveSlop || displacement < -negativeSlop else {
                        return heldSteering
                    }
                    phase = .takeover
                    takeoverOrigin = heldSteering
                    takeoverStart = time
                    stationaryDuration = isStationary ? deltaTime : 0
                    return heldSteering

                case .takeover:
                    updateStationaryDuration(
                        isStationary: isStationary,
                        deltaTime: deltaTime
                    )
                    let progress = ((time - takeoverStart) / max(deltaTime, takeoverDuration))
                        .clamped(to: 0...1)
                    let blend = Self.smootherStep(progress)
                    heldSteering = takeoverOrigin + ((actual - takeoverOrigin) * blend)
                    if progress >= 1 {
                        heldSteering = actual
                        if stationaryDuration >= restDuration {
                            armQuiet(
                                at: actual,
                                negativeSlop: currentNegativeSlop,
                                positiveSlop: currentPositiveSlop
                            )
                        } else {
                            phase = .tracking
                        }
                    }
                    return heldSteering

                case .tracking:
                    heldSteering = actual
                    updateStationaryDuration(
                        isStationary: isStationary,
                        deltaTime: deltaTime
                    )
                    if stationaryDuration >= restDuration {
                        armQuiet(
                            at: actual,
                            negativeSlop: currentNegativeSlop,
                            positiveSlop: currentPositiveSlop
                        )
                    }
                    return heldSteering
                }
            }

            mutating func reset() {
                phase = .quiet
                isInitialized = false
                previousActual = 0
                previousRaw = 0
                quietReference = 0
                heldSteering = 0
                negativeSlop = 0
                positiveSlop = 0
                takeoverOrigin = 0
                takeoverStart = 0
                stationaryDuration = 0
            }

            mutating func suspend() {
                guard isInitialized, phase != .quiet else { return }
                phase = .quiet
                quietReference = previousActual
                stationaryDuration = 0
            }

            mutating func refreshQuietSlop(
                negative: Double,
                positive: Double
            ) {
                guard isInitialized, phase == .quiet else { return }
                negativeSlop = max(0, negative)
                positiveSlop = max(0, positive)
            }

            private mutating func armQuiet(
                at position: Double,
                negativeSlop: Double,
                positiveSlop: Double
            ) {
                phase = .quiet
                quietReference = position
                heldSteering = position
                self.negativeSlop = max(0, negativeSlop)
                self.positiveSlop = max(0, positiveSlop)
                stationaryDuration = 0
            }

            private mutating func updateStationaryDuration(
                isStationary: Bool,
                deltaTime: Double
            ) {
                stationaryDuration = isStationary
                    ? stationaryDuration + deltaTime
                    : 0
            }

            private static func smootherStep(_ value: Double) -> Double {
                value * value * value * (value * ((value * 6) - 15) + 10)
            }
        }

        var persistentSegmentID: UUID?
        var anchor: CGPoint?
        private var authoredReframeID: UUID?
        private var hasZoomContext = false
        private var needsQuietSlopRefresh = false
        private var observedReframingTarget: CursorPath.ReframingTarget?
        private var activeReframingTarget: CursorPath.ReframingTarget?
        private var horizontalIntentGate = AxisIntentGate()
        private var verticalIntentGate = AxisIntentGate()

        mutating func adjust(
            _ target: Target,
            cursorPath: CursorPath?,
            at time: Double,
            sourceSize: CGSize,
            viewportInsets: CursorViewportInsets,
            configuration: Configuration
        ) -> Target {
            guard
                let segment = target.cursorVisibilitySegment
            else {
                reset()
                return target
            }

            if !hasZoomContext {
                hasZoomContext = true
                horizontalIntentGate.reset()
                verticalIntentGate.reset()
            }
            let persistentSegment = target.segment
            let followsPersistentTarget = persistentSegment != nil
            let changedPersistentSegment = persistentSegment.map {
                persistentSegmentID != $0.id
            } ?? false
            if let persistentSegment, changedPersistentSegment {
                persistentSegmentID = persistentSegment.id
                anchor = target.state.focusPoint
                authoredReframeID = target.authoredReframeID
                needsQuietSlopRefresh = true
                observedReframingTarget = nil
                activeReframingTarget = nil
            } else if
                followsPersistentTarget,
                target.authoredReframeID != nil,
                target.authoredReframeID != authoredReframeID
            {
                // Authored camera points own the composition. Start one
                // deliberate move to the new viewbox, then let cursor framing
                // intervene only if visibility is at risk.
                authoredReframeID = target.authoredReframeID
                anchor = target.state.focusPoint
                needsQuietSlopRefresh = true
                observedReframingTarget = nil
                activeReframingTarget = nil
                horizontalIntentGate.reset()
                verticalIntentGate.reset()
            }

            guard
                let cursorFrame = cursorPath?.frame(at: time),
                cursorFrame.opacity > 0
            else {
                horizontalIntentGate.suspend()
                verticalIntentGate.suspend()
                guard followsPersistentTarget, let anchor else { return target }
                return adjustedTarget(
                    target,
                    anchor: anchor,
                    sourceSize: sourceSize,
                    configuration: configuration
                )
            }

            var targetAnchor = anchor ?? target.state.focusPoint
            let targetScale = max(
                1,
                followsPersistentTarget ? target.state.scale : segment.scale
            )
            let halfWidth = sourceSize.width / (2 * targetScale)
            let halfHeight = sourceSize.height / (2 * targetScale)
            let travelZoneFraction = segment.resolvedCursorBoundaryFraction
            let activationFraction = configuration.cursorFollowActivationFraction(
                for: segment
            )
            let horizontalRange = viewportInsets.horizontalRange(
                halfExtent: halfWidth,
                viewportFraction: travelZoneFraction
            )
            let verticalRange = viewportInsets.verticalRange(
                halfExtent: halfHeight,
                viewportFraction: travelZoneFraction
            )
            let horizontalActivationRange = viewportInsets.horizontalRange(
                halfExtent: halfWidth,
                viewportFraction: activationFraction
            )
            let verticalActivationRange = viewportInsets.verticalRange(
                halfExtent: halfHeight,
                viewportFraction: activationFraction
            )

            // Rendering has the complete recorded cursor path available. Once a
            // movement burst begins, frame its endpoint (or its click) as one
            // stable composition instead of chasing every intermediate sample.
            // The current cursor remains the visibility input below, so this
            // look-ahead cannot hide it or begin during a preceding idle gap.
            let reframingTarget = cursorPath?.reframingTarget(at: time)
            if persistentSegment?.source == .automatic,
                let reframingTarget,
                reframingTarget != observedReframingTarget
            {
                observedReframingTarget = reframingTarget
                let viewportWidth = sourceSize.width / targetScale
                let viewportHeight = sourceSize.height / targetScale
                let meaningfulTravel = min(viewportWidth, viewportHeight) * 0.12
                let burstTravel = hypot(
                    reframingTarget.maximumPosition.x - reframingTarget.minimumPosition.x,
                    reframingTarget.maximumPosition.y - reframingTarget.minimumPosition.y
                )

                if burstTravel >= meaningfulTravel {
                    activeReframingTarget = reframingTarget
                    horizontalIntentGate.reset()
                    verticalIntentGate.reset()
                    targetAnchor.x = plannedAnchor(
                        current: targetAnchor.x,
                        minimumCursor: reframingTarget.minimumPosition.x,
                        maximumCursor: reframingTarget.maximumPosition.x,
                        destination: reframingTarget.position.x,
                        cursorRange: horizontalActivationRange
                    )
                    targetAnchor.y = plannedAnchor(
                        current: targetAnchor.y,
                        minimumCursor: reframingTarget.minimumPosition.y,
                        maximumCursor: reframingTarget.maximumPosition.y,
                        destination: reframingTarget.position.y,
                        cursorRange: verticalActivationRange
                    )
                    targetAnchor = CameraTrajectory.clampedFocus(
                        targetAnchor,
                        sourceSize: sourceSize,
                        scale: targetScale
                    )
                    anchor = targetAnchor
                }
            }

            if followsPersistentTarget, activeReframingTarget != nil {
                let movementDuration = activeReframingTarget.map {
                    max(0, $0.arrivalTime - $0.burstStartTime)
                } ?? 0
                var adjusted = adjustedTarget(
                    target,
                    anchor: anchor ?? targetAnchor,
                    sourceSize: sourceSize,
                    configuration: configuration,
                    responseDurationOverride: configuration.cursorReframeDuration(
                        for: targetScale,
                        movementDuration: movementDuration
                    )
                )
                adjusted.cursorSteeringPosition = cursorFrame.position
                adjusted.usesDeliberateReframe = true
                return adjusted
            }

            if reframingTarget == nil {
                observedReframingTarget = nil
            }

            let horizontalNegativeSlop = horizontalRange.lowerBound
                - horizontalActivationRange.lowerBound
            let horizontalPositiveSlop = horizontalActivationRange.upperBound
                - horizontalRange.upperBound
            let verticalNegativeSlop = verticalRange.lowerBound
                - verticalActivationRange.lowerBound
            let verticalPositiveSlop = verticalActivationRange.upperBound
                - verticalRange.upperBound
            if needsQuietSlopRefresh {
                horizontalIntentGate.refreshQuietSlop(
                    negative: horizontalNegativeSlop,
                    positive: horizontalPositiveSlop
                )
                verticalIntentGate.refreshQuietSlop(
                    negative: verticalNegativeSlop,
                    positive: verticalPositiveSlop
                )
                needsQuietSlopRefresh = false
            }
            let horizontalOuterRange = viewportInsets.horizontalRange(
                halfExtent: halfWidth,
                viewportFraction: configuration.cursorVisibilityOuterFraction
            )
            let verticalOuterRange = viewportInsets.verticalRange(
                halfExtent: halfHeight,
                viewportFraction: configuration.cursorVisibilityOuterFraction
            )
            let horizontalCursorDelta = Double(cursorFrame.position.x - targetAnchor.x)
            let verticalCursorDelta = Double(cursorFrame.position.y - targetAnchor.y)
            let steeringX = horizontalIntentGate.position(
                for: Double(cursorFrame.position.x),
                rawPosition: Double(cursorFrame.rawPosition.x),
                at: time,
                negativeSlop: horizontalNegativeSlop,
                positiveSlop: horizontalPositiveSlop,
                isOutsideSafetyRange: !horizontalOuterRange.contains(horizontalCursorDelta),
                deltaTime: 1 / configuration.sampleRate,
                takeoverDuration: configuration.cursorIntentTakeoverDuration(for: targetScale),
                restDuration: configuration.cursorIntentRestDuration
            )
            let steeringY = verticalIntentGate.position(
                for: Double(cursorFrame.position.y),
                rawPosition: Double(cursorFrame.rawPosition.y),
                at: time,
                negativeSlop: verticalNegativeSlop,
                positiveSlop: verticalPositiveSlop,
                isOutsideSafetyRange: !verticalOuterRange.contains(verticalCursorDelta),
                deltaTime: 1 / configuration.sampleRate,
                takeoverDuration: configuration.cursorIntentTakeoverDuration(for: targetScale),
                restDuration: configuration.cursorIntentRestDuration
            )
            targetAnchor.x = steeringX
                - (steeringX - Double(targetAnchor.x)).clamped(to: horizontalRange)
            targetAnchor.y = steeringY
                - (steeringY - Double(targetAnchor.y)).clamped(to: verticalRange)

            targetAnchor = CameraTrajectory.clampedFocus(
                targetAnchor,
                sourceSize: sourceSize,
                scale: targetScale
            )
            anchor = targetAnchor

            var adjusted = followsPersistentTarget
                ? adjustedTarget(
                    target,
                    anchor: targetAnchor,
                    sourceSize: sourceSize,
                    configuration: configuration
                )
                : target
            adjusted.cursorSteeringPosition = CGPoint(x: steeringX, y: steeringY)
            return adjusted
        }

        private func plannedAnchor(
            current: CGFloat,
            minimumCursor: CGFloat,
            maximumCursor: CGFloat,
            destination: CGFloat,
            cursorRange: ClosedRange<Double>
        ) -> CGFloat {
            let feasibleLowerBound = Double(maximumCursor) - cursorRange.upperBound
            let feasibleUpperBound = Double(minimumCursor) - cursorRange.lowerBound
            guard feasibleLowerBound <= feasibleUpperBound else { return destination }
            return CGFloat(Double(current).clamped(to: feasibleLowerBound...feasibleUpperBound))
        }

        private func adjustedTarget(
            _ target: Target,
            anchor: CGPoint,
            sourceSize: CGSize,
            configuration: Configuration,
            responseDurationOverride: Double? = nil
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
                if let responseDurationOverride {
                    adjusted.responseDuration = responseDurationOverride
                } else {
                    adjusted.responseDuration = min(
                        adjusted.responseDuration,
                        configuration.cursorFollowDuration(for: scale)
                    )
                }
            }
            return adjusted
        }

        mutating func reset() {
            persistentSegmentID = nil
            anchor = nil
            authoredReframeID = nil
            hasZoomContext = false
            needsQuietSlopRefresh = false
            observedReframingTarget = nil
            activeReframingTarget = nil
            horizontalIntentGate.reset()
            verticalIntentGate.reset()
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

            // A deliberate reframe already owns the camera target and timing.
            // Applying the progressive follower on top would reintroduce the
            // very sample-by-sample corrections this mode is meant to avoid.
            // `state(at:)` still applies the exact cursor-visibility rail.
            if target.usesDeliberateReframe {
                previousCursorPosition = cursorFrame.position
                previousFocusPoint = spring.value.cameraState(sourceSize: sourceSize).focusPoint
                previousPose = spring.value
                horizontalFollowAmount = 0
                verticalFollowAmount = 0
                return
            }

            let camera = spring.value.cameraState(sourceSize: sourceSize)
            let halfWidth = sourceSize.width / (2 * camera.scale)
            let halfHeight = sourceSize.height / (2 * camera.scale)
            let travelZoneFraction = segment.resolvedCursorBoundaryFraction
            let steeringPosition = target.cursorSteeringPosition ?? cursorFrame.position
            let horizontalDelta = steeringPosition.x - camera.focusPoint.x
            let verticalDelta = steeringPosition.y - camera.focusPoint.y
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
                viewportFraction: travelZoneFraction
            )
            let verticalTravelRange = viewportInsets.verticalRange(
                halfExtent: halfHeight,
                viewportFraction: travelZoneFraction
            )
            let horizontalFocusRange = Double(halfWidth)...Double(sourceSize.width - halfWidth)
            let verticalFocusRange = Double(halfHeight)...Double(sourceSize.height - halfHeight)
            let horizontal = Self.adjustedAxis(
                steeringCursor: Double(steeringPosition.x),
                actualCursor: Double(cursorFrame.position.x),
                springFocus: Double(camera.focusPoint.x),
                springDelta: Double(horizontalDelta),
                previousCursor: previousCursorPosition.map { Double($0.x) },
                previousFocus: previousFocusPoint.map { Double($0.x) },
                travelRange: horizontalTravelRange,
                outerRange: horizontalOuterRange,
                focusRange: horizontalFocusRange,
                previousFollowAmount: horizontalFollowAmount,
                deltaTime: 1 / configuration.sampleRate,
                followRampDuration: configuration.cursorFeedForwardRampDuration(for: segment.scale),
                allowsFeedForward: !target.usesDeliberateReframe
            )
            let vertical = Self.adjustedAxis(
                steeringCursor: Double(steeringPosition.y),
                actualCursor: Double(cursorFrame.position.y),
                springFocus: Double(camera.focusPoint.y),
                springDelta: Double(verticalDelta),
                previousCursor: previousCursorPosition.map { Double($0.y) },
                previousFocus: previousFocusPoint.map { Double($0.y) },
                travelRange: verticalTravelRange,
                outerRange: verticalOuterRange,
                focusRange: verticalFocusRange,
                previousFollowAmount: verticalFollowAmount,
                deltaTime: 1 / configuration.sampleRate,
                followRampDuration: configuration.cursorFeedForwardRampDuration(for: segment.scale),
                allowsFeedForward: !target.usesDeliberateReframe
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
            previousCursorPosition = steeringPosition
            previousFocusPoint = constrainedFocus
            previousPose = spring.value
        }

        private static func adjustedAxis(
            steeringCursor: Double,
            actualCursor: Double,
            springFocus: Double,
            springDelta: Double,
            previousCursor: Double?,
            previousFocus: Double?,
            travelRange: ClosedRange<Double>,
            outerRange: ClosedRange<Double>,
            focusRange: ClosedRange<Double>,
            previousFollowAmount: Double,
            deltaTime: Double,
            followRampDuration: Double,
            allowsFeedForward: Bool
        ) -> (focus: Double, didAdjust: Bool, followAmount: Double) {
            let followProgress = Self.followProgress(
                for: springDelta,
                travelRange: travelRange,
                outerRange: outerRange
            )
            var candidateFocus = springFocus
            var followAmount = 0.0
            if
                allowsFeedForward,
                followProgress > 0,
                let previousCursor,
                let previousFocus,
                Self.isMovingOutward(
                    cursorStep: steeringCursor - previousCursor,
                    cursorDelta: springDelta,
                    travelRange: travelRange
                )
            {
                let cursorStep = steeringCursor - previousCursor
                let translatedFocus = previousFocus + cursorStep
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
            let candidateDelta = actualCursor - candidateFocus
            let constrainedDelta = candidateDelta.clamped(to: outerRange)
            if constrainedDelta != candidateDelta {
                candidateFocus = actualCursor - constrainedDelta
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
        cursorViewportInsets: CursorViewportInsets,
        motionStyle: ZoomBehaviorSettings.MotionStyle
    ) {
        self.sourceSize = sourceSize
        let configuration = Configuration(motionStyle: motionStyle)
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
            ).cursorVisibilitySegment != nil,
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

        if time <= current.endTime {
            let exitDuration = current.transitionDuration
                ?? configuration.defaultTransitionDuration
            let sortedReframes = current.reframes.sorted { $0.time < $1.time }
            let activeReframe = sortedReframes.last { $0.time <= time }
            let lastReframe = sortedReframes.last
            let authoredExitStart = lastReframe.map {
                min(
                    current.endTime,
                    $0.time + configuration.authoredReframeDuration(for: $0.scale)
                )
            } ?? current.focusTime
            let exitStart = max(
                current.focusTime,
                max(current.endTime - exitDuration, authoredExitStart)
            )

            if time < exitStart {
                let state = activeReframe.map {
                    clampedState(for: $0, sourceSize: sourceSize)
                } ?? clampedState(for: current, sourceSize: sourceSize)
                return Target(
                    state: state,
                    responseDuration: activeReframe.map {
                        configuration.authoredReframeDuration(for: $0.scale)
                    } ?? max(
                        configuration.minimumTransitionDuration,
                        current.focusTime - current.startTime
                    ),
                    segment: current,
                    cursorVisibilitySegment: current,
                    usesDeliberateReframe: current.source == .manual,
                    authoredReframeID: activeReframe?.id
                )
            }

            return Target(
                state: overview.state,
                responseDuration: exitDuration,
                segment: nil,
                cursorVisibilitySegment: current
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

    private static func clampedState(
        for reframe: ZoomReframe,
        sourceSize: CGSize
    ) -> CameraState {
        let scale = max(1, reframe.scale)
        return CameraState(
            scale: scale,
            focusPoint: clampedFocus(
                reframe.focusPoint.cgPoint,
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
