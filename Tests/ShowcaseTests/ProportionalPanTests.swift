import CoreGraphics
import Foundation
import Testing
@testable import Showcase

@Suite("Proportional cursor pan")
struct ProportionalPanTests {
    private let size = CGSize(width: 1_600, height: 900)

    @Test("The inner recording area maps across the pan range at every zoom")
    func mapsFullRecordingToPanRange() {
        for scale in [1.0, 1.25, 2.0, 3.5] {
            for (x, panX) in [(0.0, 0.0), (0.1, 0.0), (0.3, 0.25), (0.5, 0.5), (0.7, 0.75), (0.9, 1.0), (1.0, 1.0)] {
                for (y, panY) in [(0.0, 0.0), (0.1, 0.0), (0.5, 0.5), (0.9, 1.0), (1.0, 1.0)] {
                    let evaluator = camera(scale: scale, points: [
                        (0, x * size.width, y * size.height)
                    ])
                    let state = evaluator.state(at: 3)
                    let halfWidth = size.width / (2 * state.scale)
                    let halfHeight = size.height / (2 * state.scale)
                    #expect(abs(state.focusPoint.x - (halfWidth + panX * (size.width - 2 * halfWidth))) < 0.01)
                    #expect(abs(state.focusPoint.y - (halfHeight + panY * (size.height - 2 * halfHeight))) < 0.01)
                }
            }
        }
    }

    @Test("Near-corner clicks reach the edges before the cursor touches the recording boundary")
    func nearCornerClicksReachEdges() {
        for scale in [1.25, 2.0, 3.5] {
            let cursor = CursorPath(events: [
                LocalizedInputEvent(timestamp: 0, type: .mouseMoved, position: CGPoint(x: 800, y: 450)),
                LocalizedInputEvent(timestamp: 1, type: .leftMouseDown, position: CGPoint(x: 1_520, y: 45))
            ], smoothing: 0.65, hideAfter: 10)
            let evaluator = CameraEvaluator(segments: [segment(scale: scale)], sourceSize: size, cursorPath: cursor)
            let state = evaluator.state(at: 2)
            #expect(abs(state.focusPoint.x + size.width / (2 * state.scale) - size.width) < 0.01)
            #expect(abs(state.focusPoint.y - size.height / (2 * state.scale)) < 0.01)
        }
    }

    @Test("Moving within the edge margin holds the edge and moving back inward releases it")
    func edgeMarginHoldsAndReleases() {
        let evaluator = camera(points: [
            (0, 1_520, 450), (1, 1_520, 450), (1.1, 1_470, 450),
            (2, 1_470, 450), (2.1, 1_400, 450)
        ])
        for time in [1.0, 1.8] {
            let state = evaluator.state(at: time)
            #expect(abs(state.focusPoint.x + size.width / (2 * state.scale) - size.width) < 0.01)
        }
        #expect(abs(evaluator.state(at: 3).focusPoint.x - 1_175) < 0.01)
    }

    @Test("Small cursor moves pan inside the former dead zone on both axes")
    func smallMovesPanImmediatelyAndSettleProportionally() {
        let evaluator = camera(points: [(0, 800, 450), (1, 800, 450), (1.1, 820, 430)])
        #expect(evaluator.state(at: 1.15).focusPoint.x > 800)
        #expect(evaluator.state(at: 1.15).focusPoint.y < 450)
        #expect(abs(evaluator.state(at: 2).focusPoint.x - 812.5) < 0.01)
        #expect(abs(evaluator.state(at: 2).focusPoint.y - 437.5) < 0.01)
    }

    @Test("Current cursor waypoints steer the camera without predicting a destination")
    func followsCurrentWaypoints() {
        let lower = camera(points: [(0, 800, 450), (1, 800, 450), (1.05, 900, 450), (1.1, 1_200, 450)])
        let higher = camera(points: [(0, 800, 450), (1, 800, 450), (1.05, 1_100, 450), (1.1, 1_200, 450)])
        #expect(lower.state(at: 0.9) == higher.state(at: 0.9))
        #expect(lower.state(at: 1.05).focusPoint.x < higher.state(at: 1.05).focusPoint.x)
        #expect(abs(lower.state(at: 2).focusPoint.x - 1_050) < 0.01)
        #expect(abs(higher.state(at: 2).focusPoint.x - 1_050) < 0.01)
    }

    @Test("Cursor following leaves entrance and exit scale timing unchanged")
    func panDoesNotChangeZoomTiming() {
        for style in [ZoomBehaviorSettings.MotionStyle.focused, .smooth] {
            let segment = segment(scale: 3)
            let reference = CameraEvaluator(segments: [segment], sourceSize: size, motionStyle: style)
            let moving = CameraEvaluator(
                segments: [segment], sourceSize: size,
                cursorPath: path([(0, 300, 200), (0.2, 1_500, 800), (4.6, 100, 100)]),
                motionStyle: style
            )
            for time in stride(from: 0.0, through: 6.0, by: 1.0 / 120) {
                #expect(abs(reference.state(at: time).scale - moving.state(at: time).scale) < 0.000_001)
            }
        }
    }

    @Test("Pan shrinks with the current zoom level during the return to overview")
    func exitKeepsProportionalPosition() {
        let evaluator = camera(points: [(0, 1_200, 225)])
        for time in stride(from: 4.5, through: 5.5, by: 1.0 / 60) {
            let state = evaluator.state(at: time)
            let viewportWidth = size.width / state.scale
            let viewportHeight = size.height / state.scale
            #expect(abs(state.focusPoint.x - (viewportWidth / 2 + 0.8125 * (size.width - viewportWidth))) < 0.01)
            #expect(abs(state.focusPoint.y - (viewportHeight / 2 + 0.1875 * (size.height - viewportHeight))) < 0.01)
        }
        #expect(evaluator.state(at: 6).scale < 1.001)
    }

    @Test("Auto-hide holds the last pan target instead of pulling back to the shot focus")
    func cursorHideHoldsPosition() {
        let evaluator = CameraEvaluator(
            segments: [segment()], sourceSize: size,
            cursorPath: path([(0, 1_200, 225)], hideAfter: 0.2)
        )
        #expect(abs(evaluator.state(at: 3).focusPoint.x - 1_050) < 0.01)
        #expect(abs(evaluator.state(at: 3).focusPoint.y - 309.375) < 0.01)
    }

    @Test("Missing or not-yet-observed cursor data uses the segment focus")
    func missingCursorFallsBackToSegment() {
        var segment = segment()
        segment.focusPoint = CodablePoint(CGPoint(x: 900, y: 400))
        let reference = CameraEvaluator(segments: [segment], sourceSize: size)
        let future = CameraEvaluator(
            segments: [segment], sourceSize: size,
            cursorPath: path([(4, 1_500, 800)])
        )
        #expect(future.state(at: 3) == reference.state(at: 3))
        #expect(abs(reference.state(at: 3).focusPoint.x - 900) < 0.01)
    }

    @Test("Saved authored reframes retain manual behavior even on an automatic segment")
    func preservesAuthoredReframes() {
        var automatic = segment()
        automatic.reframes = [ZoomReframe(time: 2, focusPoint: CodablePoint(CGPoint(x: 1_000, y: 500)), scale: 2.5)]
        var manual = automatic
        manual.source = .manual
        let cursor = path([(0, 800, 450), (2, 850, 450)])
        let existing = CameraEvaluator(segments: [automatic], sourceSize: size, cursorPath: cursor)
        let authored = CameraEvaluator(segments: [manual], sourceSize: size, cursorPath: cursor)
        #expect(!automatic.usesProportionalCursorPan)
        for time in [1.5, 2.5, 3.5] {
            #expect(existing.state(at: time) == authored.state(at: time))
        }
    }

    @Test("Seeking and separate render evaluators agree through transitions and cursor jumps")
    func deterministicAndBounded() {
        let points = [(0.0, -1.0, -1.0), (1, 1_601, 901), (2, 300, 800), (4.6, 1_600, 0)]
        let preview = camera(scale: 3.5, points: points)
        let export = camera(scale: 3.5, points: points)
        let times = Array(stride(from: 0.0, through: 6, by: 1.0 / 59))
        let expected = times.map { preview.state(at: $0) }
        for index in times.indices.reversed() {
            let state = export.state(at: times[index])
            #expect(state == expected[index])
            let halfWidth = size.width / (2 * state.scale)
            let halfHeight = size.height / (2 * state.scale)
            #expect(state.focusPoint.x >= halfWidth - 0.001)
            #expect(state.focusPoint.x <= size.width - halfWidth + 0.001)
            #expect(state.focusPoint.y >= halfHeight - 0.001)
            #expect(state.focusPoint.y <= size.height - halfHeight + 0.001)
        }
    }

    @Test("Automatic planning creates zoom ranges without cursor movement keyframes")
    func plannerDoesNotGeneratePanKeyframes() {
        let events = [
            LocalizedInputEvent(timestamp: 1, type: .leftMouseDown, position: CGPoint(x: 200, y: 100)),
            LocalizedInputEvent(timestamp: 1.2, type: .mouseMoved, position: CGPoint(x: 900, y: 800)),
            LocalizedInputEvent(timestamp: 2, type: .leftMouseDown, position: CGPoint(x: 1_400, y: 700))
        ]
        let segments = AutoZoomPlanner().plan(events: events, sourceSize: size, duration: 6)
        #expect(segments.count == 1)
        #expect(segments.allSatisfy { $0.reframes.isEmpty && $0.usesProportionalCursorPan })
    }

    private func segment(scale: Double = 2) -> ZoomSegment {
        ZoomSegment(id: UUID(), startTime: 0, focusTime: 0.5, endTime: 5,
                    focusPoint: CodablePoint(CGPoint(x: 800, y: 450)), scale: scale,
                    source: .automatic, transitionDuration: 0.5)
    }

    private func path(_ points: [(Double, Double, Double)], hideAfter: Double = 10) -> CursorPath {
        CursorPath(events: points.map {
            LocalizedInputEvent(timestamp: $0.0, type: .mouseMoved, position: CGPoint(x: $0.1, y: $0.2))
        }, smoothing: 0, hideAfter: hideAfter)
    }

    private func camera(scale: Double = 2, points: [(Double, Double, Double)]) -> CameraEvaluator {
        CameraEvaluator(segments: [segment(scale: scale)], sourceSize: size, duration: 6, cursorPath: path(points))
    }
}
