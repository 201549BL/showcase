import CoreGraphics
import Testing
@testable import SmoothScreen

@Suite("Editor geometry")
struct EditorGeometryTests {
    @Test("Timeline maps time and position in both directions")
    func timelineMapping() {
        let geometry = TimelineGeometry(duration: 20, width: 1_000)

        #expect(geometry.x(for: 5) == 250)
        #expect(geometry.time(for: 750) == 15)
        #expect(geometry.width(from: 4, to: 7) == 150)
        #expect(geometry.timeDelta(for: -100) == -2)
        #expect(geometry.x(for: -1) == 0)
        #expect(geometry.time(for: 1_500) == 20)
    }

    @Test("Preview center maps to the selected camera focus")
    func previewCenterMapping() throws {
        let mapper = makeMapper()
        let point = try #require(mapper.sourcePoint(for: CGPoint(x: 960, y: 540)))

        #expect(point.x == 800)
        #expect(point.y == 450)
    }

    @Test("Preview offsets account for zoom and letterboxing")
    func previewOffsetMapping() throws {
        var mapper = makeMapper(viewSize: CGSize(width: 2_400, height: 1_080))
        let point = try #require(mapper.sourcePoint(for: CGPoint(x: 1_360, y: 700)))

        #expect(point.x == 900)
        #expect(point.y == 550)

        mapper = makeMapper(viewSize: CGSize(width: 2_400, height: 1_080))
        #expect(mapper.sourcePoint(for: CGPoint(x: 100, y: 540)) == nil)
        #expect(mapper.sourcePoint(for: CGPoint(x: 250, y: 20)) == nil)
    }

    @Test("Selected timeline block stays above overlapping neighbors")
    func selectedTimelineBlockStacking() {
        let selected = TimelineBlockStacking.zIndex(isSelected: true, order: 0)
        let laterNeighbor = TimelineBlockStacking.zIndex(isSelected: false, order: 3)

        #expect(selected > laterNeighbor)
    }

    private func makeMapper(
        viewSize: CGSize = CGSize(width: 1_920, height: 1_080)
    ) -> PreviewFocusMapper {
        PreviewFocusMapper(
            viewSize: viewSize,
            canvasSize: CGSize(width: 1_920, height: 1_080),
            screenRect: CGRect(x: 160, y: 90, width: 1_600, height: 900),
            sourceSize: CGSize(width: 1_600, height: 900),
            cameraFocus: CGPoint(x: 800, y: 450),
            cameraScale: 1.6
        )
    }
}
