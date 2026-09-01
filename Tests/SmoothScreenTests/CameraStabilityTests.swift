import CoreGraphics
import Foundation
import Testing
@testable import SmoothScreen

@Suite("Camera stability")
struct CameraStabilityTests {
    @Test("Camera following absorbs abrupt changes in cursor velocity")
    func cursorVelocityChangesAreDamped() {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0,
            focusTime: 0,
            endTime: 3,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: 1.6,
            source: .automatic
        )
        let cursorPath = CursorPath(
            events: [
                localized(time: 0, x: 800),
                localized(time: 0.4, x: 820),
                localized(time: 0.7, x: 1_080),
                localized(time: 1.0, x: 1_090),
                localized(time: 1.25, x: 1_250),
                localized(time: 1.6, x: 1_260)
            ],
            smoothing: 0.65,
            hideAfter: 2
        )
        let evaluator = CameraEvaluator(
            segments: [segment],
            sourceSize: CGSize(width: 1_600, height: 900),
            cursorPath: cursorPath
        )

        let maximumJerk = maximumFocusJerk(evaluator: evaluator, duration: 2)

        #expect(maximumJerk < 2)
    }

    private func maximumFocusJerk(evaluator: CameraEvaluator, duration: Double) -> Double {
        let states = (0...Int(duration * 60)).map {
            evaluator.state(at: Double($0) / 60)
        }
        var previousAcceleration = CGVector.zero
        var maximumJerk = 0.0
        for index in 2..<states.count {
            let current = states[index].focusPoint
            let previous = states[index - 1].focusPoint
            let beforePrevious = states[index - 2].focusPoint
            let acceleration = CGVector(
                dx: current.x - (2 * previous.x) + beforePrevious.x,
                dy: current.y - (2 * previous.y) + beforePrevious.y
            )
            if index > 2 {
                maximumJerk = max(
                    maximumJerk,
                    hypot(
                        acceleration.dx - previousAcceleration.dx,
                        acceleration.dy - previousAcceleration.dy
                    )
                )
            }
            previousAcceleration = acceleration
        }
        return maximumJerk
    }

    private func localized(time: Double, x: Double) -> LocalizedInputEvent {
        LocalizedInputEvent(
            timestamp: time,
            type: .mouseMoved,
            position: CGPoint(x: x, y: 450)
        )
    }
}
