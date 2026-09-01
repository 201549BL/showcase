import CoreGraphics
import Foundation

struct RecordedInputEvent: Codable, Equatable {
    enum EventType: String, Codable {
        case mouseMoved
        case leftMouseDown
        case leftMouseUp
        case rightMouseDown
        case rightMouseUp
        case leftMouseDragged
        case rightMouseDragged
        case scrollWheel
        case keyDown
        case keyUp
        case flagsChanged
    }

    let timestamp: Double
    let type: EventType
    let position: CodablePoint?
    let buttonNumber: Int64?
    let scrollDeltaX: Double?
    let scrollDeltaY: Double?
    let keyCode: Int64?
    let flags: UInt64
}
