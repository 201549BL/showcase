import CoreGraphics
import Foundation
import Testing
@testable import Showcase

@Suite("Zoom segment bindings")
struct ZoomSegmentBindingTests {
    @Test("A retained binding safely outlives preset segment replacement")
    func retainedBindingSurvivesSegmentReplacement() {
        let oldSegment = zoom(scale: 1.75)
        let replacement = zoom(scale: 2.2)
        let reference = ZoomSegmentBindingReference(fallback: oldSegment)

        #expect(reference.value(in: [oldSegment], keyPath: \.scale) == 1.75)
        #expect(reference.value(in: [replacement], keyPath: \.scale) == 1.75)
        #expect(reference.index(in: [replacement]) == nil)
    }

    private func zoom(scale: Double) -> ZoomSegment {
        ZoomSegment(
            id: UUID(),
            startTime: 1,
            focusTime: 1.5,
            endTime: 3,
            focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
            scale: scale,
            source: .automatic
        )
    }
}
