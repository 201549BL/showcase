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

    @Test("Zoom viewbox is drawn over the corresponding source area")
    func viewboxRectMapping() {
        let mapper = makeViewboxMapper()

        let rect = mapper.viewboxRect(
            focusPoint: CGPoint(x: 800, y: 450),
            scale: 2
        )

        #expect(rect == CGRect(x: 560, y: 315, width: 800, height: 450))
    }

    @Test("Dragging a viewbox moves its focus and keeps it inside the source")
    func viewboxDragMapping() {
        let mapper = makeViewboxMapper()

        let moved = mapper.focusPoint(
            moving: CGPoint(x: 800, y: 450),
            by: CGSize(width: 160, height: 90),
            scale: 2
        )
        let clamped = mapper.focusPoint(
            moving: CGPoint(x: 400, y: 225),
            by: CGSize(width: -800, height: -450),
            scale: 2
        )

        #expect(moved == CGPoint(x: 960, y: 540))
        #expect(clamped == CGPoint(x: 400, y: 225))
    }

    @Test("Dragging a viewbox corner changes magnification within editor limits")
    func viewboxResizeMapping() {
        let mapper = makeViewboxMapper()
        let focus = CGPoint(x: 800, y: 450)

        let tighter = mapper.scale(
            resizingHandleTo: CGPoint(x: 1_160, y: 652.5),
            focusPoint: focus,
            initialScale: 2,
            allowedRange: 1.1...3.5
        )
        let wider = mapper.scale(
            resizingHandleTo: CGPoint(x: 1_760, y: 990),
            focusPoint: focus,
            initialScale: 2,
            allowedRange: 1.1...3.5
        )

        #expect(tighter == 3.5)
        #expect(wider == 1.1)
    }

    @Test("Selected timeline block stays above overlapping neighbors")
    func selectedTimelineBlockStacking() {
        let selected = TimelineBlockStacking.zIndex(isSelected: true, order: 0)
        let laterNeighbor = TimelineBlockStacking.zIndex(isSelected: false, order: 3)

        #expect(selected > laterNeighbor)
    }

    @Test("Timeline drag remains anchored while the block moves")
    func stableTimelineDragProjection() {
        let projection = TimelineDragProjection(
            initialTime: 4,
            pointerStartX: 100,
            geometry: TimelineGeometry(duration: 20, width: 1_000)
        )

        #expect(projection.time(atPointerX: 250) == 7)
        #expect(projection.time(atPointerX: 50) == 3)
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

    private func makeViewboxMapper() -> PreviewViewboxMapper {
        PreviewViewboxMapper(
            viewSize: CGSize(width: 1_920, height: 1_080),
            canvasSize: CGSize(width: 1_920, height: 1_080),
            screenRect: CGRect(x: 160, y: 90, width: 1_600, height: 900),
            sourceSize: CGSize(width: 1_600, height: 900)
        )
    }
}
