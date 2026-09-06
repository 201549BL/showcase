import CoreGraphics
import Foundation

struct RecordedInputEvent: Codable, Equatable {
    enum CursorStyle: String, Codable, CaseIterable {
        case arrow
        case pointingHand
        case iBeam
        case openHand
        case closedHand
        case crosshair
        case resizeHorizontal
        case resizeVertical
        case operationNotAllowed
        case dragCopy
        case dragLink

        var draggingVariant: Self {
            switch self {
            case .openHand, .closedHand:
                return .closedHand
            default:
                return self
            }
        }
    }

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
    var sourceFrame: CodableRect? = nil
    let buttonNumber: Int64?
    let scrollDeltaX: Double?
    let scrollDeltaY: Double?
    let keyCode: Int64?
    let flags: UInt64
    var cursorStyle: CursorStyle? = nil
}
