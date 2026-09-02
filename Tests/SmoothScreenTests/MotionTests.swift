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

    @Test("Rapid opposite-side cursor travel keeps the camera wider")
    func distantCursorTravelUsesOverviewScale() {
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

        #expect(evaluator.state(at: 2.7).scale < 1.5)
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
