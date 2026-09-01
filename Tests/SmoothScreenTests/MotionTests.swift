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
        #expect(evaluator.state(at: 1.4).scale == 1.6)
        #expect(evaluator.state(at: 2).focusPoint == CGPoint(x: 500, y: 300))
        #expect(evaluator.state(at: 3.1).focusPoint == CGPoint(x: 800, y: 450))
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

    @Test("Camera follows the cursor only after it leaves the travel zone")
    func cameraFollowsCursorThroughTravelZone() {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 1,
            focusTime: 1.4,
            endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 500, y: 400)),
            scale: 1.6,
            source: .automatic
        )
        let cursorPath = CursorPath(
            events: [
                localized(time: 1.4, type: .mouseMoved, x: 500, y: 400),
                localized(time: 2.4, type: .mouseMoved, x: 850, y: 400)
            ],
            smoothing: 0,
            hideAfter: 2
        )
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: CGSize(width: 1_600, height: 900),
            cursorPath: cursorPath
        )

        let followedState = evaluator.state(at: 2.4)

        #expect(followedState.scale > 1.5)
        #expect(followedState.focusPoint.x > 500)
        #expect(followedState.focusPoint.x < 850)
    }

    @Test("Camera zooms out when the cursor travels too far")
    func cameraZoomsOutForLongTravel() {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 1,
            focusTime: 1.4,
            endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 400, y: 400)),
            scale: 1.6,
            source: .automatic
        )
        let cursorPath = CursorPath(
            events: [
                localized(time: 1.4, type: .mouseMoved, x: 400, y: 400),
                localized(time: 2.4, type: .mouseMoved, x: 1_400, y: 400)
            ],
            smoothing: 0,
            hideAfter: 2
        )
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: CGSize(width: 1_600, height: 900),
            cursorPath: cursorPath
        )

        #expect(evaluator.state(at: 2.4).scale < 1.25)
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
        point: CGPoint
    ) -> RecordedInputEvent {
        RecordedInputEvent(
            timestamp: time,
            type: type,
            position: CodablePoint(point),
            buttonNumber: nil,
            scrollDeltaX: nil,
            scrollDeltaY: nil,
            keyCode: nil,
            flags: 0
        )
    }
}
