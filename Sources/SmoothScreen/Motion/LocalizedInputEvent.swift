import CoreGraphics
import Foundation

struct LocalizedInputEvent: Equatable {
    let timestamp: Double
    let type: RecordedInputEvent.EventType
    let position: CGPoint?

    var isPrimaryClick: Bool { type == .leftMouseDown }

    var isCursorActivity: Bool {
        switch type {
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
             .rightMouseUp, .leftMouseDragged, .rightMouseDragged:
            return true
        case .scrollWheel, .keyDown, .keyUp, .flagsChanged:
            return false
        }
    }
}

struct InputEventLocalizer {
    func localize(
        _ events: [RecordedInputEvent],
        source: CaptureSourceDescriptor,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [LocalizedInputEvent] {
        let sourceFrame = source.frame.cgRect
        let scaleX = sourceFrame.width > 0 ? Double(pixelWidth) / sourceFrame.width : source.scaleFactor
        let scaleY = sourceFrame.height > 0 ? Double(pixelHeight) / sourceFrame.height : source.scaleFactor
        let pixelBounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)

        return events.map { event in
            let localPosition = event.position.map { position -> CGPoint? in
                let point = CGPoint(
                    x: (position.x - sourceFrame.minX) * scaleX,
                    y: (position.y - sourceFrame.minY) * scaleY
                )
                return pixelBounds.insetBy(dx: -1, dy: -1).contains(point) ? point : nil
            } ?? nil

            return LocalizedInputEvent(
                timestamp: event.timestamp,
                type: event.type,
                position: localPosition
            )
        }
    }
}
