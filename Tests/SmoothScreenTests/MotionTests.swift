import CoreGraphics
import Foundation
import Testing
@testable import SmoothScreen

@Suite("Motion generation")
struct MotionTests {
    @Test("Localizes global cursor coordinates into recording pixels")
    func localizesInputCoordinates() {
        let source = CaptureSourceDescriptor(
            kind: .window,
            sourceID: 1,
            title: "Window",
            applicationName: "App",
            frame: CodableRect(CGRect(x: 100, y: 50, width: 800, height: 600)),
            scaleFactor: 2
        )
        let events = [inputEvent(time: 1, type: .mouseMoved, point: CGPoint(x: 300, y: 200))]

        let result = InputEventLocalizer().localize(
            events,
            source: source,
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )

        #expect(result[0].position == CGPoint(x: 400, y: 300))
    }

    @Test("Localizes cursor coordinates after the captured window moves")
    func localizesInputCoordinatesAfterWindowMoves() {
        let source = CaptureSourceDescriptor(
            kind: .window,
            sourceID: 1,
            title: "Window",
            applicationName: "App",
            frame: CodableRect(CGRect(x: 100, y: 50, width: 800, height: 600)),
            scaleFactor: 2
        )
        let events = [inputEvent(
            time: 5,
            type: .mouseMoved,
            point: CGPoint(x: 1_200, y: 250),
            sourceFrame: CGRect(x: 1_000, y: 100, width: 800, height: 600)
        )]

        let result = InputEventLocalizer().localize(
            events,
            source: source,
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )

        #expect(result[0].position == CGPoint(x: 400, y: 300))
    }

    @Test("Tracks live window bounds without looking them up for every event")
    func tracksLiveWindowBoundsWithCaching() {
        let source = CaptureSourceDescriptor(
            kind: .window,
            sourceID: 42,
            title: "Window",
            applicationName: "App",
            frame: CodableRect(CGRect(x: 100, y: 50, width: 800, height: 600)),
            scaleFactor: 2
        )
        var lookupCount = 0
        var tracker = SourceFrameTracker(
            source: source,
            refreshInterval: 0.5,
            windowFrameLookup: { windowID in
                lookupCount += 1
                #expect(windowID == 42)
                return CGRect(x: 1_000, y: 100, width: 900, height: 700)
            }
        )

        #expect(tracker.frame(at: 0) == CGRect(x: 1_000, y: 100, width: 900, height: 700))
        #expect(tracker.frame(at: 0.1) == CGRect(x: 1_000, y: 100, width: 900, height: 700))
        #expect(lookupCount == 1)
        _ = tracker.frame(at: 0.5)
        #expect(lookupCount == 2)
    }

    @Test("Drops cursor coordinates outside the captured source")
    func removesOutsideCoordinates() {
        let source = captureSource(width: 800, height: 600)
        let events = [inputEvent(time: 1, type: .mouseMoved, point: CGPoint(x: 900, y: 700))]

        let result = InputEventLocalizer().localize(
            events,
            source: source,
            pixelWidth: 800,
            pixelHeight: 600
        )

        #expect(result[0].position == nil)
    }

    @Test("Cursor smoothing preserves exact click positions")
    func cursorPreservesClicks() {
        let events = [
            localized(time: 0, type: .mouseMoved, x: 0, y: 0),
            localized(time: 0.1, type: .mouseMoved, x: 120, y: 30),
            localized(time: 0.2, type: .leftMouseDown, x: 200, y: 100),
            localized(time: 0.3, type: .mouseMoved, x: 260, y: 140)
        ]

        let path = CursorPath(events: events, smoothing: 1, hideAfter: 2)
        let click = path.keyframes.first { $0.isClickAnchor }

        #expect(click?.position == CGPoint(x: 200, y: 100))
        #expect(click?.rawPosition == click?.position)
    }

    @Test("Cursor fades after inactivity")
    func cursorFadesAfterInactivity() {
        let path = CursorPath(
            events: [localized(time: 0, type: .mouseMoved, x: 20, y: 20)],
            smoothing: 0.5,
            hideAfter: 1,
            fadeDuration: 0.2
        )

        #expect(path.frame(at: 0.5)?.opacity == 1)
        #expect(abs((path.frame(at: 1.1)?.opacity ?? 0) - 0.5) < 0.001)
        #expect(path.frame(at: 1.3)?.opacity == 0)
    }

    @Test("Cursor does not drift toward a future event across an idle gap")
    func cursorHoldsPositionAcrossIdleGaps() {
        let path = CursorPath(
            events: [
                localized(time: 0, type: .mouseMoved, x: 20, y: 20),
                localized(time: 2, type: .mouseMoved, x: 32, y: 20)
            ],
            smoothing: 0,
            hideAfter: 2
        )

        #expect(path.frame(at: 1)?.position == CGPoint(x: 20, y: 20))
        #expect(path.frame(at: 2)?.position == CGPoint(x: 32, y: 20))
    }

    @Test("Cursor still interpolates between nearby movement samples")
    func cursorInterpolatesAcrossActiveGaps() {
        let path = CursorPath(
            events: [
                localized(time: 0, type: .mouseMoved, x: 20, y: 20),
                localized(time: 0.1, type: .mouseMoved, x: 40, y: 20)
            ],
            smoothing: 0,
            hideAfter: 2
        )

        #expect(path.frame(at: 0.05)?.position == CGPoint(x: 30, y: 20))
    }

    @Test("Cursor smoothing settles at the observed endpoint during an idle gap")
    func cursorSmoothingSettlesDuringIdleGaps() throws {
        let path = CursorPath(
            events: [
                localized(time: 0, type: .mouseMoved, x: 0, y: 20),
                localized(time: 0.04, type: .mouseMoved, x: 40, y: 20),
                localized(time: 0.08, type: .mouseMoved, x: 80, y: 20),
                localized(time: 1, type: .mouseMoved, x: 80, y: 20),
                localized(time: 1.04, type: .mouseMoved, x: 40, y: 20)
            ],
            smoothing: 1,
            hideAfter: 2
        )

        let filteredEndpoint = try #require(
            path.keyframes.first { abs($0.timestamp - 0.08) < 0.000_001 }
        )
        let settled = try #require(path.frame(at: 0.21))
        let beforeNextBurst = try #require(path.frame(at: 0.999))
        let nextBurstStart = try #require(path.frame(at: 1))

        #expect(filteredEndpoint.position.x < filteredEndpoint.rawPosition.x)
        #expect(abs(settled.position.x - 80) < 0.001)
        #expect(abs(beforeNextBurst.position.x - 80) < 0.001)
        #expect(abs(nextBurstStart.position.x - beforeNextBurst.position.x) < 0.001)
    }

    @Test("Cursor smoothing does not leak a future burst across the idle boundary")
    func cursorSmoothingIsolatedAcrossIdleGaps() throws {
        let path = CursorPath(
            events: [
                localized(time: 0, type: .mouseMoved, x: 0, y: 20),
                localized(time: 0.05, type: .mouseMoved, x: 0, y: 20),
                localized(time: 0.171, type: .mouseMoved, x: 1_000, y: 20),
                localized(time: 0.221, type: .mouseMoved, x: 1_000, y: 20)
            ],
            smoothing: 1,
            hideAfter: 2
        )

        for time in [0.025, 0.05, 0.1, 0.17] {
            let frame = try #require(path.frame(at: time))
            #expect(abs(frame.position.x) < 0.001)
        }
        #expect(abs(try #require(path.frame(at: 0.171)).position.x - 1_000) < 0.001)
    }

    @Test("Cursor smoothing enters a fast burst without jumping ahead")
    func cursorSmoothingStartsBurstsContinuously() throws {
        let path = CursorPath(
            events: [
                localized(time: 0, type: .mouseMoved, x: 100, y: 20),
                localized(time: 1, type: .mouseMoved, x: 100, y: 20),
                localized(time: 1.01, type: .mouseMoved, x: 110, y: 20),
                localized(time: 1.02, type: .mouseMoved, x: 400, y: 20),
                localized(time: 1.03, type: .mouseMoved, x: 700, y: 20),
                localized(time: 1.04, type: .mouseMoved, x: 900, y: 20)
            ],
            smoothing: 0.65,
            hideAfter: 2
        )

        let burstStart = try #require(path.frame(at: 1))
        let secondSample = try #require(path.frame(at: 1.01))
        let rawStep = burstStart.rawPosition.distance(to: secondSample.rawPosition)
        let smoothedStep = burstStart.position.distance(to: secondSample.position)

        #expect(rawStep == 10)
        // The uncorrected backward pass jumped more than 320 points here.
        #expect(smoothedStep < 80)
    }

    @Test("Nearby clicks become one stable zoom")
    func mergesNearbyClicks() {
        let events = [
            localized(time: 1, type: .leftMouseDown, x: 300, y: 300),
            localized(time: 1.6, type: .leftMouseDown, x: 340, y: 320),
            localized(time: 4, type: .leftMouseDown, x: 1_400, y: 700)
        ]

        let segments = AutoZoomPlanner().plan(
            events: events,
            sourceSize: CGSize(width: 1_600, height: 900),
            duration: 7
        )

        #expect(segments.count == 2)
        #expect(segments[0].startTime == 0.8)
        #expect(segments[0].endTime == 3)
    }

    @Test("Ignores the recording-stop click at the end of the timeline")
    func ignoresRecordingStopClick() {
        let events = [
            localized(time: 1, type: .leftMouseDown, x: 300, y: 300),
            localized(time: 9.8, type: .leftMouseDown, x: 1_200, y: 700)
        ]

        let segments = AutoZoomPlanner().plan(
            events: events,
            sourceSize: CGSize(width: 1_600, height: 900),
            duration: 10
        )

        #expect(segments.count == 1)
    }

    @Test("Rapid far-apart clicks become one stable overview shot")
    func rapidClicksUseOverviewShot() {
        let events = [
            localized(time: 1, type: .leftMouseDown, x: 200, y: 200),
            localized(time: 1.7, type: .leftMouseDown, x: 1_400, y: 700),
            localized(time: 2.4, type: .leftMouseDown, x: 200, y: 200),
            localized(time: 3.1, type: .leftMouseDown, x: 1_400, y: 700)
        ]

        let segments = AutoZoomPlanner().plan(
            events: events,
            sourceSize: CGSize(width: 1_600, height: 900),
            duration: 5
        )

        #expect(segments.count == 1)
        #expect(segments[0].scale < 1.3)
        #expect(segments[0].focusPoint.cgPoint == CGPoint(x: 800, y: 450))
    }

    @Test("Calm groups more interactions with wider framing than Focused")
    func zoomBehaviorPresets() {
        let events = [
            localized(time: 1, type: .leftMouseDown, x: 300, y: 300),
            localized(time: 2.8, type: .leftMouseDown, x: 1_300, y: 600)
        ]
        let sourceSize = CGSize(width: 1_600, height: 900)

        let calm = AutoZoomPlanner(settings: .calm).plan(
            events: events,
            sourceSize: sourceSize,
            duration: 6
        )
        let focused = AutoZoomPlanner(settings: .focused).plan(
            events: events,
            sourceSize: sourceSize,
            duration: 6
        )

        #expect(calm.count == 1)
        #expect(focused.count == 2)
        #expect(calm[0].scale < focused[0].scale)
        #expect(calm[0].transitionDuration == ZoomBehaviorSettings.calm.transitionDuration)
    }

    @Test("Per-segment transition controls the zoom-out timing")
    func segmentTransitionDuration() {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 1,
            focusTime: 1.4,
            endTime: 3,
            focusPoint: CodablePoint(CGPoint(x: 500, y: 400)),
            scale: 1.6,
            source: .automatic,
            transitionDuration: 1
        )
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: CGSize(width: 1_600, height: 900)
        )

        #expect(evaluator.state(at: 2.25).scale < 1.6)
        #expect(evaluator.state(at: 2.25).scale > 1)
    }

    @Test("Zoom focus is clamped away from source edges")
    func clampsZoomFocus() {
        let segments = AutoZoomPlanner().plan(
            events: [localized(time: 1, type: .leftMouseDown, x: 0, y: 0)],
            sourceSize: CGSize(width: 1_600, height: 900),
            duration: 3
        )

        #expect(segments[0].focusPoint.x == 500)
        #expect(segments[0].focusPoint.y == 281.25)
    }

    @Test("Camera returns to the source center outside zooms")
    func cameraTiming() {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 1,
            focusTime: 1.4,
            endTime: 3,
            focusPoint: CodablePoint(CGPoint(x: 500, y: 300)),
            scale: 1.6,
            source: .automatic
        )
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: CGSize(width: 1_600, height: 900)
        )

        #expect(evaluator.state(at: 0).scale == 1)
        #expect(evaluator.state(at: 1.4).scale > 1.5)
        #expect(evaluator.state(at: 2).focusPoint.distance(to: CGPoint(x: 500, y: 300)) < 1)
        #expect(evaluator.state(at: 3.1).focusPoint.distance(to: CGPoint(x: 800, y: 450)) < 2)
    }

    @Test("Camera stays zoomed while traveling between nearby interactions")
    func cameraKeepsContextBetweenNearbyInteractions() {
        let segments = [
            ZoomSegment(
                id: UUID(),
                startTime: 1,
                focusTime: 1.4,
                endTime: 3,
                focusPoint: CodablePoint(CGPoint(x: 500, y: 400)),
                scale: 1.6,
                source: .automatic
            ),
            ZoomSegment(
                id: UUID(),
                startTime: 4,
                focusTime: 4.4,
                endTime: 6,
                focusPoint: CodablePoint(CGPoint(x: 760, y: 440)),
                scale: 1.6,
                source: .automatic
            )
        ]
        let evaluator = CameraEvaluator(
            segments: segments,
            sourceSize: CGSize(width: 1_600, height: 900)
        )

        let travelingState = evaluator.state(at: 3.5)

        #expect(travelingState.scale > 1.3)
        #expect(travelingState.focusPoint.x > 500)
        #expect(travelingState.focusPoint.x < 760)
    }

    @Test("Overlapping interaction shots become one continuous pan")
    func cameraPansAcrossOverlappingShots() {
        let segments = [
            ZoomSegment(
                id: UUID(),
                startTime: 1,
                focusTime: 1.4,
                endTime: 3,
                focusPoint: CodablePoint(CGPoint(x: 500, y: 400)),
                scale: 1.6,
                source: .automatic
            ),
            ZoomSegment(
                id: UUID(),
                startTime: 2.4,
                focusTime: 3,
                endTime: 5,
                focusPoint: CodablePoint(CGPoint(x: 1_100, y: 400)),
                scale: 1.6,
                source: .automatic
            )
        ]
        let evaluator = CameraEvaluator(
            segments: segments,
            sourceSize: CGSize(width: 1_600, height: 900)
        )

        let travelingState = evaluator.state(at: 2.7)

        #expect(abs(travelingState.scale - 1.6) < 0.01)
        #expect(travelingState.focusPoint.x > 500)
        #expect(travelingState.focusPoint.x < 1_100)
        #expect(abs(1_100 - travelingState.focusPoint.x) < 500)
    }

    @Test("Camera does not snap back after reaching an overlapping target")
    func cameraKeepsNewestOverlappingTarget() {
        let segments = [
            ZoomSegment(
                id: UUID(),
                startTime: 1,
                focusTime: 1.4,
                endTime: 4,
                focusPoint: CodablePoint(CGPoint(x: 500, y: 400)),
                scale: 1.4,
                source: .automatic
            ),
            ZoomSegment(
                id: UUID(),
                startTime: 2,
                focusTime: 2.6,
                endTime: 5,
                focusPoint: CodablePoint(CGPoint(x: 1_100, y: 400)),
                scale: 1.75,
                source: .automatic
            )
        ]
        let evaluator = CameraEvaluator(
            segments: segments,
            sourceSize: CGSize(width: 1_600, height: 900)
        )
        let frameDuration = 1.0 / 60.0

        let atTarget = evaluator.state(at: 2.6)
        let nextFrame = evaluator.state(at: 2.6 + frameDuration)

        let targetPose = normalizedPose(
            atTarget,
            sourceSize: CGSize(width: 1_600, height: 900)
        )
        let nextPose = normalizedPose(
            nextFrame,
            sourceSize: CGSize(width: 1_600, height: 900)
        )

        #expect(hypot(nextPose.x - targetPose.x, nextPose.y - targetPose.y) < 0.04)
        #expect(abs(nextPose.logScale - targetPose.logScale) < 0.04)
    }

    @Test("Rapid alternating targets remain frame-continuous")
    func rapidAlternatingTargetsStayStable() {
        let segments = [
            zoom(start: 1, focus: 1.4, end: 4, x: 500, scale: 1.4),
            zoom(start: 1.8, focus: 2.2, end: 4.8, x: 1_100, scale: 1.75),
            zoom(start: 2.6, focus: 3, end: 5.6, x: 500, scale: 1.4),
            zoom(start: 3.4, focus: 3.8, end: 6.4, x: 1_100, scale: 1.75)
        ]
        let sourceSize = CGSize(width: 1_600, height: 900)
        let evaluator = CameraEvaluator(segments: segments, sourceSize: sourceSize)
        let poses = stride(from: 3.8, through: 5.7, by: 1.0 / 60.0).map {
            normalizedPose(evaluator.state(at: $0), sourceSize: sourceSize)
        }

        let steps = zip(poses, poses.dropFirst())
        let maximumTranslationStep = steps.map {
            hypot($1.x - $0.x, $1.y - $0.y)
        }.max() ?? 0
        let maximumZoomStep = zip(poses, poses.dropFirst()).map {
            abs($1.logScale - $0.logScale)
        }.max() ?? 0

        #expect(maximumTranslationStep < 0.04)
        #expect(maximumZoomStep < 0.04)
    }

    @Test("Combined pan and zoom have continuous acceleration")
    func simultaneousPanAndZoomStaySmooth() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let evaluator = CameraEvaluator(
            segments: [zoom(start: 1, focus: 1.4, end: 3, x: 1_100, scale: 1.75)],
            sourceSize: sourceSize
        )
        let frameDuration = 1.0 / 60.0
        let midpoint = 1.2
        let poses = (-2...2).map { offset in
            normalizedPose(
                evaluator.state(at: midpoint + Double(offset) * frameDuration),
                sourceSize: sourceSize
            )
        }
        let leftAcceleration = secondDifference(poses[0], poses[1], poses[2], dt: frameDuration)
        let rightAcceleration = secondDifference(poses[2], poses[3], poses[4], dt: frameDuration)

        #expect(
            hypot(
                rightAcceleration.x - leftAcceleration.x,
                rightAcceleration.y - leftAcceleration.y
            ) < 25
        )
        #expect(abs(rightAcceleration.logScale - leftAcceleration.logScale) < 15)
    }

    @Test("Automatic camera follows only after the cursor leaves its travel zone")
    func automaticCameraUsesCursorTravelZone() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 5,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.6,
            source: .automatic
        )
        let insidePath = cursorPath([
            (0, 800, 450),
            (4, 1_000, 450)
        ])
        let outsidePath = cursorPath([
            (0, 800, 450),
            (1.9, 800, 450),
            (2, 1_500, 450),
            (4, 1_500, 450)
        ])
        let inside = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 5,
            cursorPath: insidePath
        )
        let outside = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 5,
            cursorPath: outsidePath
        )

        #expect(abs(inside.state(at: 3).focusPoint.x - 800) < 2)
        #expect(outside.state(at: 3).focusPoint.x > 950)
    }

    @Test("Small cursor tremor does not trigger a delayed camera micro-pan")
    func smallBoundaryCursorTremorDoesNotTriggerDelayedPan() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 6,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let path = cursorPath([
            // Park at the current travel-zone edge and let the shot settle.
            (0, 1_097, 450),
            (3, 1_097, 450),
            // A twelve-pixel hand adjustment should not disturb a settled shot.
            (3.1, 1_109, 450)
        ])
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 6,
            cursorPath: path
        )

        let sampleTimes = Array(stride(from: 3.0, through: 4.5, by: 1.0 / 60.0))
        let settledFocus = evaluator.state(at: 3).focusPoint.x
        let focusAfterTremor = sampleTimes.map {
            evaluator.state(at: $0).focusPoint.x
        }
        let maximumDrift = focusAfterTremor.map { abs($0 - settledFocus) }.max() ?? 0
        let settledViewportWidth = sourceSize.width / evaluator.state(at: 3).scale
        let driftAsViewportFraction = maximumDrift / settledViewportWidth
        let focusWhenCursorStops = evaluator.state(at: 3.1).focusPoint.x
        let tailDriftAsViewportFraction = abs((focusAfterTremor.last ?? 0) - focusWhenCursorStops)
            / settledViewportWidth
        let maximumOuterOverflow = sampleTimes.compactMap { time -> CGFloat? in
            guard let cursor = path.frame(at: time)?.position else { return nil }
            let camera = evaluator.state(at: time)
            let halfWidth = sourceSize.width / (2 * camera.scale)
            return max(0, abs(cursor.x - camera.focusPoint.x) - halfWidth)
        }.max() ?? 0

        #expect(maximumOuterOverflow < 0.001)
        #expect(driftAsViewportFraction < 0.005)
        #expect(tailDriftAsViewportFraction < 0.002)
    }

    @Test("Settled cursor-follow pan ignores a small same-direction tremor")
    func settledFollowedPanIgnoresSameDirectionTremor() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 6,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let path = cursorPath([
            (0, 800, 450),
            (1, 800, 450),
            // Trigger a deliberate rightward follow, then let the input rest.
            (1.2, 1_250, 450),
            (3, 1_250, 450),
            // Continue in the same direction by only twelve pixels.
            (3.1, 1_262, 450)
        ])
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 6,
            cursorPath: path
        )

        let settledState = evaluator.state(at: 3)
        let sampleTimes = Array(stride(from: 3.0, through: 4.5, by: 1.0 / 60.0))
        let focusPositions = sampleTimes.map {
            Double(evaluator.state(at: $0).focusPoint.x)
        }
        let controlPath = cursorPath([
            (0, 800, 450),
            (1, 800, 450),
            (1.2, 1_250, 450),
            (3, 1_250, 450),
            (3.1, 1_250, 450)
        ])
        let control = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 6,
            cursorPath: controlPath
        )
        let controlFocusPositions = sampleTimes.map {
            Double(control.state(at: $0).focusPoint.x)
        }
        let maximumAdditionalDrift = zip(focusPositions, controlFocusPositions).map {
            abs($0 - $1)
        }.max() ?? 0
        let additionalDriftAsViewportFraction = maximumAdditionalDrift
            / (sourceSize.width / settledState.scale)

        #expect(settledState.focusPoint.x > 900)
        #expect(additionalDriftAsViewportFraction < 0.000_001)
    }

    @Test("Cursor smoothing tail does not postpone the camera rest gate")
    func smoothedCursorTailDoesNotPostponeIntentRearm() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        var commonEvents = [
            localized(time: 0, type: .mouseMoved, x: 800, y: 450)
        ]
        commonEvents += (0...24).map { index in
            let progress = Double(index) / 24
            return localized(
                time: 0.8 + (progress * 0.4),
                type: .mouseMoved,
                x: 800 + (progress * 450),
                y: 450
            )
        }
        let movingPath = CursorPath(
            events: commonEvents + [
                localized(time: 1.35, type: .mouseMoved, x: 1_262, y: 450)
            ],
            smoothing: 0.65,
            hideAfter: 2
        )
        let controlPath = CursorPath(
            events: commonEvents + [
                localized(time: 1.35, type: .mouseMoved, x: 1_250, y: 450)
            ],
            smoothing: 0.65,
            hideAfter: 2
        )
        let moving = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: movingPath
        )
        let control = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: controlPath
        )

        let maximumAdditionalDrift = stride(
            from: 1.35,
            through: 2.5,
            by: 1.0 / 120.0
        ).map {
            abs(moving.state(at: $0).focusPoint.x - control.state(at: $0).focusPoint.x)
        }.max() ?? 0

        #expect(maximumAdditionalDrift < 0.001)
    }

    @Test("A real sparse cursor stream rearms before a later tremor")
    func sparseCursorEventsDoNotSmearTremorBackward() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 6,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let movingPath = cursorPath([
            (0, 800, 450),
            (1, 800, 450),
            (1.2, 1_250, 450),
            (3.1, 1_262, 450)
        ])
        let controlPath = cursorPath([
            (0, 800, 450),
            (1, 800, 450),
            (1.2, 1_250, 450),
            (3.1, 1_250, 450)
        ])
        let moving = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 6,
            cursorPath: movingPath
        )
        let control = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 6,
            cursorPath: controlPath
        )

        let maximumAdditionalDrift = stride(
            from: 1.2,
            through: 4.5,
            by: 1.0 / 120.0
        ).map {
            abs(moving.state(at: $0).focusPoint.x - control.state(at: $0).focusPoint.x)
        }.max() ?? 0

        #expect(maximumAdditionalDrift < 0.001)
    }

    @Test("Slow intent crossing starts one smooth camera takeover")
    func slowActivationCrossingDoesNotRatchetCamera() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 7,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        var cursorEvents: [(Double, Double, Double)] = [
            // Settle at the 65% travel line, then cross the 72% intent line.
            (0, 1_097, 450),
            (3, 1_097, 450)
        ]
        cursorEvents += (1...20).map { index in
            let progress = Double(index) / 20
            return (3 + progress, 1_097 + (34 * progress), 450)
        }
        let path = cursorPath(cursorEvents)
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 7,
            cursorPath: path
        )

        let settledFocus = evaluator.state(at: 3).focusPoint.x
        let intentCrossingTime = 3 + (32.0 / 34.0)
        let focusAtCrossing = evaluator.state(at: intentCrossingTime).focusPoint.x
        let earlyTakeoverDrift = abs(
            evaluator.state(at: intentCrossingTime + 0.05).focusPoint.x - focusAtCrossing
        )
        let focusPositions = stride(
            from: intentCrossingTime,
            through: intentCrossingTime + 0.3,
            by: 1.0 / 120.0
        ).map {
            Double(evaluator.state(at: $0).focusPoint.x)
        }
        let frameSteps = zip(focusPositions, focusPositions.dropFirst()).map {
            $1 - $0
        }
        let totalTakeoverDrift = abs((focusPositions.last ?? 0) - Double(focusAtCrossing))

        #expect(abs(focusAtCrossing - settledFocus) < 0.5)
        #expect(earlyTakeoverDrift < 2)
        #expect((frameSteps.map(abs).max() ?? 0) < 1.5)
        #expect(totalTakeoverDrift > 10)
    }

    @Test("Small cursor tremor stays quiet during automatic zoom-out")
    func exitTremorDoesNotBypassCursorIntentGate() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 3,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic,
            transitionDuration: 0.5
        )
        let movingPath = cursorPath([
            (0, 800, 450),
            (1, 800, 450),
            (1.2, 1_250, 450),
            (2.55, 1_250, 450),
            (2.65, 1_262, 450)
        ])
        let controlPath = cursorPath([
            (0, 800, 450),
            (1, 800, 450),
            (1.2, 1_250, 450),
            (2.55, 1_250, 450),
            (2.65, 1_250, 450)
        ])
        let moving = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: movingPath
        )
        let control = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: controlPath
        )

        let maximumAdditionalDrift = stride(
            from: 2.5,
            through: 3.5,
            by: 1.0 / 120.0
        ).map {
            abs(moving.state(at: $0).focusPoint.x - control.state(at: $0).focusPoint.x)
        }.max() ?? 0

        #expect(maximumAdditionalDrift < 0.001)
    }

    @Test("Connected automatic shots preserve pending cursor intent")
    func connectedShotsDoNotResetCursorIntentGate() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segments = [
            ZoomSegment(
                id: UUID(),
                startTime: 0,
                focusTime: 0.5,
                endTime: 4,
                focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
                scale: 1.75,
                source: .automatic,
                transitionDuration: 0.5
            ),
            ZoomSegment(
                id: UUID(),
                startTime: 4.5,
                focusTime: 5,
                endTime: 7,
                focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
                scale: 1.75,
                source: .automatic,
                transitionDuration: 0.5
            )
        ]
        let movingPath = cursorPath([
            (0, 1_097, 450),
            (3, 1_097, 450),
            (3.1, 1_128, 450),
            (7, 1_128, 450)
        ])
        let controlPath = cursorPath([
            (0, 1_097, 450),
            (3, 1_097, 450),
            (3.1, 1_097, 450),
            (7, 1_097, 450)
        ])
        let moving = CameraEvaluator(
            segments: segments,
            sourceSize: sourceSize,
            duration: 7,
            cursorPath: movingPath
        )
        let control = CameraEvaluator(
            segments: segments,
            sourceSize: sourceSize,
            duration: 7,
            cursorPath: controlPath
        )

        let maximumAdditionalDrift = stride(
            from: 3.1,
            through: 5.5,
            by: 1.0 / 120.0
        ).map {
            abs(moving.state(at: $0).focusPoint.x - control.state(at: $0).focusPoint.x)
        }.max() ?? 0

        #expect(maximumAdditionalDrift < 0.001)
    }

    @Test("Hidden connected shot handoff refreshes cursor intent scale")
    func hiddenConnectedShotRefreshesCursorIntentSlop() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segments = [
            ZoomSegment(
                id: UUID(),
                startTime: 0,
                focusTime: 0.5,
                endTime: 4,
                focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
                scale: 3,
                source: .automatic,
                transitionDuration: 0.5
            ),
            ZoomSegment(
                id: UUID(),
                startTime: 4.5,
                focusTime: 5,
                endTime: 7,
                focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
                scale: 1.75,
                source: .automatic,
                transitionDuration: 0.5
            )
        ]
        let movingSamples = [
            (0.0, 1_097.0, 450.0),
            (3.0, 1_097.0, 450.0),
            (4.0, 1_097.0, 450.0),
            (4.1, 1_122.0, 450.0),
            (7.0, 1_122.0, 450.0)
        ]
        let controlSamples = movingSamples.map { time, _, y in
            (time, 1_097.0, y)
        }
        let movingPath = cursorPathWithShortHide(movingSamples)
        let controlPath = cursorPathWithShortHide(controlSamples)
        let moving = CameraEvaluator(
            segments: segments,
            sourceSize: sourceSize,
            duration: 7,
            cursorPath: movingPath
        )
        let control = CameraEvaluator(
            segments: segments,
            sourceSize: sourceSize,
            duration: 7,
            cursorPath: controlPath
        )

        let maximumAdditionalDrift = stride(
            from: 4.0,
            through: 5.5,
            by: 1.0 / 120.0
        ).map {
            abs(moving.state(at: $0).focusPoint.x - control.state(at: $0).focusPoint.x)
        }.max() ?? 0

        #expect(maximumAdditionalDrift < 0.001)
    }

    @Test("Cursor intent survives auto-hide and reappearance")
    func cursorReappearancePreservesQuietIntentGate() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 6,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let movingEvents = [
            (0.0, 800.0, 450.0),
            (1.0, 800.0, 450.0),
            (1.2, 1_250.0, 450.0),
            (2.0, 1_250.0, 450.0),
            (3.999, 1_250.0, 450.0),
            (4.0, 1_262.0, 450.0)
        ]
        let controlEvents = movingEvents.dropLast() + [(4.0, 1_250.0, 450.0)]
        let movingPath = CursorPath(
            events: movingEvents.map {
                localized(time: $0.0, type: .mouseMoved, x: $0.1, y: $0.2)
            },
            smoothing: 0,
            hideAfter: 0.2
        )
        let controlPath = CursorPath(
            events: controlEvents.map {
                localized(time: $0.0, type: .mouseMoved, x: $0.1, y: $0.2)
            },
            smoothing: 0,
            hideAfter: 0.2
        )
        let moving = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 6,
            cursorPath: movingPath
        )
        let control = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 6,
            cursorPath: controlPath
        )

        let maximumAdditionalDrift = stride(
            from: 4.0,
            through: 5.25,
            by: 1.0 / 120.0
        ).map {
            abs(moving.state(at: $0).focusPoint.x - control.state(at: $0).focusPoint.x)
        }.max() ?? 0

        #expect(maximumAdditionalDrift < 0.001)
    }

    @Test("Repeated cursor reappearances preserve accumulated intent")
    func repeatedCursorReappearancesDoNotResetQuietReference() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 7,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let path = cursorPathWithShortHide([
            (0, 1_097, 450),
            (1, 1_097, 450),
            (2, 1_128, 450),
            (3, 1_159, 450),
            (4, 1_190, 450),
            (5, 1_221, 450),
            (6, 1_252, 450)
        ])
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 7,
            cursorPath: path
        )

        #expect(evaluator.state(at: 3.5).focusPoint.x > 840)
        for time in stride(from: 0.0, through: 7.0, by: 1.0 / 120.0) {
            guard let cursorFrame = path.frame(at: time), cursorFrame.opacity > 0 else {
                continue
            }
            let camera = evaluator.state(at: time)
            let halfWidth = sourceSize.width / (2 * camera.scale)
            #expect(abs(cursorFrame.position.x - camera.focusPoint.x) <= halfWidth + 0.001)
        }
    }

    @Test("Repeated slow cursor steps accumulate into one intentional pan")
    func repeatedSlowCursorStepsPreserveIntent() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 66,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let samples = (0...60).map { index in
            (1.0 + Double(index), 1_097.0 + Double(index), 450.0)
        }
        let path = cursorPath([(0, 1_097, 450)] + samples)
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 66,
            cursorPath: path
        )

        let finalFocus = evaluator.state(at: 62).focusPoint.x
        #expect(finalFocus > 825)
        #expect(finalFocus < 845)
    }

    @Test("Automatic camera keeps fast cursor travel inside the viewport")
    func automaticCameraFramesFastCursorTravel() throws {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let path = cursorPath([
            (0, 800, 450),
            (1, 800, 450),
            (1.001, 1_590, 450),
            (4, 1_590, 450)
        ])
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: path
        )

        for time in [1.001, 1.025, 1.05] {
            let cursor = try #require(path.frame(at: time)?.position)
            let camera = evaluator.state(at: time)
            let halfWidth = sourceSize.width / (2 * camera.scale)
            let halfHeight = sourceSize.height / (2 * camera.scale)
            #expect(abs(cursor.x - camera.focusPoint.x) <= halfWidth + 0.001)
            #expect(abs(cursor.y - camera.focusPoint.y) <= halfHeight + 0.001)
        }
    }

    @Test("Automatic camera keeps the cursor visible while zooming out")
    func automaticCameraFramesCursorDuringZoomOut() throws {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let cursorInsets = CursorViewportInsets(
            left: 2 / 960,
            right: 30 / 960,
            top: 2 / 540,
            bottom: 46 / 540
        )
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 3,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic,
            transitionDuration: 0.5
        )
        let path = cursorPath([
            (0, 1_575, 450),
            (2.49, 1_575, 450),
            (4, 1_575, 450)
        ])
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: path,
            cursorViewportInsets: cursorInsets
        )

        for time in stride(from: 2.5, through: 3.4, by: 1.0 / 60.0) {
            let cursor = try #require(path.frame(at: time)?.position)
            let camera = evaluator.state(at: time)
            let halfWidth = sourceSize.width / (2 * camera.scale)
            let safeRange = cursorInsets.horizontalRange(
                halfExtent: halfWidth,
                viewportFraction: 1
            )
            let cursorDelta = Double(cursor.x - camera.focusPoint.x)
            #expect(cursorDelta >= safeRange.lowerBound - 0.001)
            #expect(cursorDelta <= safeRange.upperBound + 0.001)
        }
    }

    @Test("Automatic camera does not pan before the cursor moves")
    func automaticCameraDoesNotLeadStationaryCursor() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let path = cursorPath([
            (0, 800, 450),
            (0.99, 800, 450),
            (1, 1_590, 450),
            (4, 1_590, 450)
        ])
        let following = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: path
        )
        let plannedOnly = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: nil
        )

        #expect(following.state(at: 0.9) == plannedOnly.state(at: 0.9))
        #expect(following.state(at: 0.98) == plannedOnly.state(at: 0.98))
    }

    @Test("Calm camera contains fast cursor travel without anticipatory zoom")
    func calmCameraFramesFastCursorTravel() throws {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let click = localized(time: 0.5, type: .leftMouseDown, x: 800, y: 450)
        let segment = try #require(
            AutoZoomPlanner(settings: .calm).plan(
                events: [click],
                sourceSize: sourceSize,
                duration: 4
            ).first
        )
        let path = cursorPath([
            (0, 800, 450),
            (1.1, 800, 450),
            (1.2, 1_000, 450),
            (1.3, 1_200, 450),
            (1.4, 1_400, 450),
            (1.5, 1_590, 450),
            (2, 1_590, 450)
        ])
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: path
        )

        #expect(abs((segment.focusTime - segment.startTime) - 0.9) < 0.001)
        var poses: [NormalizedCameraPose] = []
        for time in stride(from: 1.1, through: 1.6, by: 1.0 / 60.0) {
            let cursor = try #require(path.frame(at: time)?.position)
            let camera = evaluator.state(at: time)
            poses.append(normalizedPose(camera, sourceSize: sourceSize))
            let halfWidth = sourceSize.width / (2 * camera.scale)
            let halfHeight = sourceSize.height / (2 * camera.scale)
            #expect(abs(cursor.x - camera.focusPoint.x) <= halfWidth + 0.001)
            #expect(abs(cursor.y - camera.focusPoint.y) <= halfHeight + 0.001)
        }
        let maximumTranslationStep = zip(poses, poses.dropFirst()).map {
            hypot($1.x - $0.x, $1.y - $0.y)
        }.max() ?? 0
        #expect(maximumTranslationStep < 0.05)
    }

    @Test("Dense cursor travel accelerates and stops without a camera snap")
    func denseCursorTravelStaysSmooth() throws {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let click = localized(time: 0.5, type: .leftMouseDown, x: 800, y: 450)
        let segment = try #require(
            AutoZoomPlanner(settings: .calm).plan(
                events: [click],
                sourceSize: sourceSize,
                duration: 4
            ).first
        )
        var cursorEvents = [localized(time: 0, type: .mouseMoved, x: 800, y: 450)]
        cursorEvents += (0...24).map { index in
            let progress = Double(index) / 24
            return localized(
                time: 1.1 + (progress * 0.4),
                type: .mouseMoved,
                x: 800 + (progress * 790),
                y: 450
            )
        }
        cursorEvents.append(localized(time: 2, type: .mouseMoved, x: 1_590, y: 450))
        let path = CursorPath(events: cursorEvents, smoothing: 0.65, hideAfter: 2)
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: path
        )
        let focusPositions = stride(from: 1.0, through: 1.7, by: 1.0 / 60.0).map {
            Double(evaluator.state(at: $0).focusPoint.x)
        }
        let frameSteps = zip(focusPositions, focusPositions.dropFirst()).map {
            $1 - $0
        }
        let velocities = frameSteps.map { $0 * 60 }
        let accelerations = zip(velocities, velocities.dropFirst()).map {
            abs($1 - $0) * 60
        }

        #expect((frameSteps.map(abs).max() ?? 0) < 30)
        #expect((accelerations.max() ?? 0) < 30_000)
        #expect(directionReversals(in: focusPositions, minimumStep: 0.25) == 0)
    }

    @Test("Cursor moving inward from an edge does not pull the camera back outward")
    func inwardCursorTravelDoesNotReverseCamera() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.4,
            source: .automatic
        )
        var cursorEvents = [localized(time: 0, type: .mouseMoved, x: 800, y: 450)]
        cursorEvents += (0...24).map { index in
            let progress = Double(index) / 24
            return localized(
                time: 1 + (progress * 0.4),
                type: .mouseMoved,
                x: 800 + (progress * 800),
                y: 450
            )
        }
        cursorEvents.append(localized(time: 1.9, type: .mouseMoved, x: 1_600, y: 450))
        cursorEvents += (0...24).map { index in
            let progress = Double(index) / 24
            return localized(
                time: 2 + (progress * 0.4),
                type: .mouseMoved,
                x: 1_600 - (progress * 800),
                y: 450
            )
        }
        let path = CursorPath(events: cursorEvents, smoothing: 0.65, hideAfter: 2)
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: path
        )
        let inwardFocusPositions = stride(from: 2.0, through: 2.5, by: 1.0 / 60.0).map {
            Double(evaluator.state(at: $0).focusPoint.x)
        }
        let outwardSteps = zip(inwardFocusPositions, inwardFocusPositions.dropFirst()).map {
            $1 - $0
        }

        #expect((outwardSteps.max() ?? 0) < 0.25)
    }

    @Test("Full-width cursor return re-engages the camera without an acceleration pulse")
    func fullWidthCursorReturnStaysSmooth() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 5,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.4,
            source: .automatic
        )
        var cursorEvents = [localized(time: 0, type: .mouseMoved, x: 800, y: 450)]
        cursorEvents += (0...24).map { index in
            let progress = Double(index) / 24
            return localized(
                time: 1 + (progress * 0.4),
                type: .mouseMoved,
                x: 800 + (progress * 800),
                y: 450
            )
        }
        cursorEvents.append(localized(time: 1.9, type: .mouseMoved, x: 1_600, y: 450))
        cursorEvents += (0...48).map { index in
            let progress = Double(index) / 48
            return localized(
                time: 2 + (progress * 0.8),
                type: .mouseMoved,
                x: 1_600 - (progress * 1_600),
                y: 450
            )
        }
        cursorEvents.append(localized(time: 3.3, type: .mouseMoved, x: 0, y: 450))
        let path = CursorPath(events: cursorEvents, smoothing: 0.65, hideAfter: 2)
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 5,
            cursorPath: path
        )
        let focusPositions = stride(from: 2.0, through: 3.2, by: 1.0 / 60.0).map {
            Double(evaluator.state(at: $0).focusPoint.x)
        }
        let frameSteps = zip(focusPositions, focusPositions.dropFirst()).map {
            $1 - $0
        }
        let velocities = frameSteps.map { $0 * 60 }
        let accelerations = zip(velocities, velocities.dropFirst()).map {
            abs($1 - $0) * 60
        }
        #expect((frameSteps.max() ?? 0) < 0.25)
        #expect((frameSteps.map(abs).max() ?? 0) < 30)
        #expect((accelerations.max() ?? 0) < 35_000)
    }

    @Test("Invisible stale cursor positions do not steer a later shot")
    func automaticCameraIgnoresInvisibleCursor() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 2,
            focusTime: 2.5,
            endTime: 5,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.6,
            source: .automatic
        )
        let path = CursorPath(
            events: [localized(time: 0, type: .mouseMoved, x: 1_500, y: 450)],
            smoothing: 0,
            hideAfter: 0.2
        )
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 5,
            cursorPath: path
        )

        #expect(abs(evaluator.state(at: 3).focusPoint.x - 800) < 2)
    }

    @Test("Camera follows the cursor until its current frame has faded")
    func automaticCameraUsesCurrentCursorOpacity() throws {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 3,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let path = CursorPath(
            events: [localized(time: 0, type: .mouseMoved, x: 1_590, y: 450)],
            smoothing: 0,
            hideAfter: 0.2
        )
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 3,
            cursorPath: path
        )

        for time in [0.1, 0.3] {
            let cursorFrame = try #require(path.frame(at: time))
            #expect(cursorFrame.opacity > 0)
            let camera = evaluator.state(at: time)
            let halfWidth = sourceSize.width / (2 * camera.scale)
            #expect(abs(cursorFrame.position.x - camera.focusPoint.x) <= halfWidth + 0.001)
        }
    }

    @Test("Rapid opposite-side cursor travel does not pulse the zoom")
    func distantCursorTravelKeepsShotScaleStable() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 6,
            focusPoint: CodablePoint(CGPoint(x: 500, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let path = cursorPath([
            (0, 500, 450),
            (1.49, 500, 450),
            (1.5, 1_500, 450),
            (1.99, 1_500, 450),
            (2, 100, 450),
            (2.49, 100, 450),
            (2.5, 1_500, 450),
            (4, 1_500, 450)
        ])
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 6,
            cursorPath: path
        )

        let scales = stride(from: 1.2, through: 3.2, by: 1.0 / 60.0).map {
            evaluator.state(at: $0).scale
        }

        #expect((scales.max() ?? 0) - (scales.min() ?? 0) < 0.01)
        #expect(abs((scales.last ?? 0) - segment.scale) < 0.01)
    }

    @Test("One-way cursor travel does not reverse the camera direction")
    func oneWayCursorTravelDoesNotReverseCamera() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.75,
            source: .automatic
        )
        let path = cursorPath([
            (1, 800, 450),
            (1.01, 1_500, 450)
        ])
        let followingEvaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: path
        )
        let plannedOnlyEvaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 4,
            cursorPath: nil
        )
        // Continue beyond the cursor fade, but stop before the shot's intended exit.
        // Losing the followed anchor on fade used to make this pan back early.
        let sampleTimes = stride(from: 1.0, through: 3.45, by: 1.0 / 60.0)
        let followingStates = sampleTimes.map(followingEvaluator.state)
        let plannedStates = sampleTimes.map(plannedOnlyEvaluator.state)
        let followingFocusPositions = followingStates.map {
            Double($0.focusPoint.x)
        }
        let plannedFocusPositions = plannedStates.map {
            Double($0.focusPoint.x)
        }
        let followingRenderedPositions = followingStates.map {
            normalizedPose($0, sourceSize: sourceSize).x
        }
        let plannedRenderedPositions = plannedStates.map {
            normalizedPose($0, sourceSize: sourceSize).x
        }
        let followingFocusReversals = directionReversals(
            in: followingFocusPositions,
            minimumStep: 0.25
        )
        let plannedFocusReversals = directionReversals(
            in: plannedFocusPositions,
            minimumStep: 0.25
        )
        let followingRenderedReversals = directionReversals(
            in: followingRenderedPositions,
            minimumStep: 0.000_1
        )
        let plannedRenderedReversals = directionReversals(
            in: plannedRenderedPositions,
            minimumStep: 0.000_1
        )

        #expect(plannedFocusReversals == 0)
        #expect(plannedRenderedReversals == 0)
        #expect(followingFocusReversals == plannedFocusReversals)
        #expect(followingRenderedReversals == plannedRenderedReversals)
    }

    @Test("Manual camera focus ignores cursor following")
    func manualZoomRemainsAuthoritative() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0.5,
            endTime: 5,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.6,
            source: .manual
        )
        let path = cursorPath([
            (0, 1_500, 450),
            (4, 1_500, 450)
        ])
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: sourceSize,
            duration: 5,
            cursorPath: path
        )

        #expect(abs(evaluator.state(at: 3).focusPoint.x - 800) < 2)
    }

    @Test("Spring camera never exposes pixels beyond the source")
    func springCameraRemainsInBounds() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let segments = [
            zoom(start: 0.5, focus: 0.9, end: 3, x: 500, scale: 1.75),
            zoom(start: 1.4, focus: 1.8, end: 4, x: 1_100, scale: 1.3),
            zoom(start: 2.3, focus: 2.7, end: 5, x: 500, scale: 2.2)
        ]
        let path = cursorPath([
            (0, 0, 0),
            (1, 1_600, 900),
            (2, 0, 900),
            (3, 1_600, 0),
            (5, 800, 450)
        ])
        let evaluator = CameraEvaluator(
            segments: segments,
            sourceSize: sourceSize,
            duration: 5,
            cursorPath: path
        )

        for time in stride(from: 0.0, through: 6.0, by: 1.0 / 60.0) {
            let state = evaluator.state(at: time)
            let halfWidth = sourceSize.width / (2 * state.scale)
            let halfHeight = sourceSize.height / (2 * state.scale)
            #expect(state.focusPoint.x >= halfWidth - 0.001)
            #expect(state.focusPoint.x <= sourceSize.width - halfWidth + 0.001)
            #expect(state.focusPoint.y >= halfHeight - 0.001)
            #expect(state.focusPoint.y <= sourceSize.height - halfHeight + 0.001)
        }
    }

    @Test("Camera evaluation is deterministic for out-of-order render requests")
    func cameraSupportsOutOfOrderRendering() {
        let sourceSize = CGSize(width: 1_600, height: 900)
        let evaluator = CameraEvaluator(
            segments: [
                zoom(start: 1, focus: 1.4, end: 3, x: 500, scale: 1.4),
                zoom(start: 2, focus: 2.5, end: 5, x: 1_100, scale: 1.75)
            ],
            sourceSize: sourceSize,
            duration: 5
        )
        let times = [0.25, 1.2, 2.35, 3.7, 4.9]
        let chronological = times.map(evaluator.state)
        let shuffledIndices = [3, 0, 4, 1, 2]

        for index in shuffledIndices {
            #expect(evaluator.state(at: times[index]) == chronological[index])
        }
    }

    @Test("Automatic zoom holds its focus for the duration of a shot")
    func cameraHoldsFocusForShot() {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 1,
            focusTime: 1.4,
            endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 500, y: 400)),
            scale: 1.6,
            source: .automatic
        )
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: CGSize(width: 1_600, height: 900)
        )

        let firstState = evaluator.state(at: 2)
        let heldState = evaluator.state(at: 3.2)

        #expect(abs(heldState.scale - 1.6) < 0.001)
        #expect(heldState.focusPoint.distance(to: CGPoint(x: 500, y: 400)) < 0.1)
        #expect(heldState.focusPoint.distance(to: firstState.focusPoint) < 0.1)
    }

    @Test("Camera zooms out between distant interaction targets")
    func cameraZoomsOutForDistantInteractions() {
        let segments = [
            ZoomSegment(
                id: UUID(),
                startTime: 1,
                focusTime: 1.4,
                endTime: 3,
                focusPoint: CodablePoint(CGPoint(x: 500, y: 400)),
                scale: 1.6,
                source: .automatic
            ),
            ZoomSegment(
                id: UUID(),
                startTime: 4,
                focusTime: 4.4,
                endTime: 6,
                focusPoint: CodablePoint(CGPoint(x: 1_100, y: 400)),
                scale: 1.6,
                source: .automatic
            )
        ]
        let evaluator = CameraEvaluator(
            segments: segments,
            sourceSize: CGSize(width: 1_600, height: 900)
        )

        #expect(evaluator.state(at: 3.5).scale < 1.001)
    }

    private func captureSource(width: Double, height: Double) -> CaptureSourceDescriptor {
        CaptureSourceDescriptor(
            kind: .display,
            sourceID: 1,
            title: "Display",
            applicationName: nil,
            frame: CodableRect(CGRect(x: 0, y: 0, width: width, height: height)),
            scaleFactor: 1
        )
    }

    private func localized(
        time: Double,
        type: RecordedInputEvent.EventType,
        x: Double,
        y: Double
    ) -> LocalizedInputEvent {
        LocalizedInputEvent(timestamp: time, type: type, position: CGPoint(x: x, y: y))
    }

    private func inputEvent(
        time: Double,
        type: RecordedInputEvent.EventType,
        point: CGPoint,
        sourceFrame: CGRect? = nil
    ) -> RecordedInputEvent {
        RecordedInputEvent(
            timestamp: time,
            type: type,
            position: CodablePoint(point),
            sourceFrame: sourceFrame.map(CodableRect.init),
            buttonNumber: nil,
            scrollDeltaX: nil,
            scrollDeltaY: nil,
            keyCode: nil,
            flags: 0
        )
    }

    private func zoom(
        start: Double,
        focus: Double,
        end: Double,
        x: Double,
        scale: Double
    ) -> ZoomSegment {
        ZoomSegment(
            id: UUID(),
            startTime: start,
            focusTime: focus,
            endTime: end,
            focusPoint: CodablePoint(CGPoint(x: x, y: 400)),
            scale: scale,
            source: .automatic
        )
    }

    private func normalizedPose(
        _ state: CameraState,
        sourceSize: CGSize
    ) -> NormalizedCameraPose {
        NormalizedCameraPose(
            x: 0.5 - (state.focusPoint.x / sourceSize.width) * state.scale,
            y: 0.5 - ((sourceSize.height - state.focusPoint.y) / sourceSize.height) * state.scale,
            logScale: log(state.scale)
        )
    }

    private func cursorPath(_ samples: [(Double, Double, Double)]) -> CursorPath {
        CursorPath(
            events: samples.map { time, x, y in
                LocalizedInputEvent(
                    timestamp: time,
                    type: .mouseMoved,
                    position: CGPoint(x: x, y: y)
                )
            },
            smoothing: 0,
            hideAfter: 2
        )
    }

    private func cursorPathWithShortHide(
        _ samples: [(Double, Double, Double)]
    ) -> CursorPath {
        CursorPath(
            events: samples.map { time, x, y in
                LocalizedInputEvent(
                    timestamp: time,
                    type: .mouseMoved,
                    position: CGPoint(x: x, y: y)
                )
            },
            smoothing: 0,
            hideAfter: 0.2
        )
    }

    private func directionReversals(
        in positions: [Double],
        minimumStep: Double
    ) -> Int {
        let meaningfulDirections = zip(positions, positions.dropFirst())
            .map { $1 - $0 }
            .filter { abs($0) >= minimumStep }
            .map { $0 > 0 ? 1 : -1 }
        return zip(meaningfulDirections, meaningfulDirections.dropFirst())
            .filter { $0 != $1 }
            .count
    }

    private func secondDifference(
        _ first: NormalizedCameraPose,
        _ second: NormalizedCameraPose,
        _ third: NormalizedCameraPose,
        dt: Double
    ) -> NormalizedCameraPose {
        let denominator = dt * dt
        return NormalizedCameraPose(
            x: (third.x - 2 * second.x + first.x) / denominator,
            y: (third.y - 2 * second.y + first.y) / denominator,
            logScale: (third.logScale - 2 * second.logScale + first.logScale) / denominator
        )
    }
}

private struct NormalizedCameraPose {
    let x: Double
    let y: Double
    let logScale: Double
}
