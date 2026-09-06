import CoreGraphics
import Foundation
import Testing
@testable import Showcase

@Suite("Zoom timing")
struct ZoomTimingTests {
    @Test("Legacy zoom with focus at its end enters, holds and exits inside its block",
           arguments: [ZoomBehaviorSettings.MotionStyle.focused, .smooth])
    func brokenLegacyTiming(style: ZoomBehaviorSettings.MotionStyle) {
        let segment = zoom(start: 8.284539, focus: 9.992528, end: 9.992528)
        let evaluator = CameraEvaluator(segments: [segment], sourceSize: CGSize(width: 920, height: 464),
                                        duration: 11, motionStyle: style)
        #expect(evaluator.state(at: 9.1).scale > 2)
        #expect(evaluator.state(at: 9.8).scale < evaluator.state(at: 9.3).scale)
        #expect(evaluator.state(at: segment.endTime).scale < 1.001)
    }

    @Test("Short zooms fit both transitions inside the block", arguments: [0.1, 0.25, 0.6])
    func shortZoom(duration: Double) {
        let segment = zoom(start: 1, focus: 1 + duration, end: 1 + duration)
        let evaluator = CameraEvaluator(segments: [segment], sourceSize: CGSize(width: 920, height: 464),
                                        duration: 3, motionStyle: .smooth)
        #expect(evaluator.state(at: 1 + duration / 2).scale > 1.1)
        #expect(evaluator.state(at: 1 + duration).scale < 1.001)
    }

    @Test("Preferred durations survive saving a shortened clip and extending it")
    func timingRoundTrip() throws {
        var segment = zoom(start: 1, focus: 1.5, end: 4)
        segment.normalizeTiming()
        segment.endTime = 1.2
        segment.normalizeTiming()
        var restored = try JSONDecoder().decode(ZoomSegment.self, from: JSONEncoder().encode(segment))
        restored.endTime = 5
        restored.normalizeTiming()
        #expect(restored.focusTime == 1.5)
        #expect(restored.timing.exitDuration == 0.5)
        #expect(restored.scale == segment.scale)
        #expect(restored.id == segment.id)
    }

    @Test("Manual and automatic clips share their zoom envelope")
    func sameTimingForBothSources() {
        let manual = zoom(start: 1, focus: 1.5, end: 3)
        var automatic = manual
        automatic.source = .automatic
        let size = CGSize(width: 920, height: 464)
        let first = CameraEvaluator(segments: [manual], sourceSize: size, motionStyle: .smooth)
        let second = CameraEvaluator(segments: [automatic], sourceSize: size, motionStyle: .smooth)
        for time in stride(from: 1.0, through: 3.2, by: 1.0 / 60) {
            #expect(abs(first.state(at: time).scale - second.state(at: time).scale) < 0.000_001)
        }
    }

    private func zoom(start: Double, focus: Double, end: Double) -> ZoomSegment {
        ZoomSegment(id: UUID(), startTime: start, focusTime: focus, endTime: end,
                    focusPoint: CodablePoint(CGPoint(x: 460, y: 232)), scale: 2.22, source: .manual)
    }
}
