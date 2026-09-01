import ApplicationServices
import CoreMedia
import Foundation

final class InputEventRecorder {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case eventTapCreationFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Input Monitoring permission is required to record cursor and click metadata."
            case .eventTapCreationFailed:
                return "macOS could not create the input event monitor."
            }
        }
    }

    private let lock = NSLock()
    private var capturedEvents: [RecordedInputEvent] = []
    private var startTime: CMTime = .zero
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var thread: Thread?
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let finishedSemaphore = DispatchSemaphore(value: 0)
    private var startupError: Error?

    func start(at startTime: CMTime, requestPermission: Bool = true) throws {
        if requestPermission, !CGPreflightListenEventAccess() {
            guard CGRequestListenEventAccess() else {
                throw RecorderError.permissionDenied
            }
        }

        lock.withLock {
            capturedEvents.removeAll(keepingCapacity: true)
            self.startTime = startTime
            startupError = nil
        }

        let thread = Thread { [weak self] in
            self?.runEventLoop()
        }
        thread.name = "SmoothScreen.InputEvents"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()

        _ = readySemaphore.wait(timeout: .now() + 2)
        if let startupError = lock.withLock({ startupError }) {
            throw startupError
        }
    }

    func stop() -> [RecordedInputEvent] {
        let currentRunLoop = lock.withLock { runLoop }
        if let currentRunLoop {
            CFRunLoopStop(currentRunLoop)
            _ = finishedSemaphore.wait(timeout: .now() + 2)
        }
        thread = nil
        return lock.withLock {
            capturedEvents.sorted { $0.timestamp < $1.timestamp }
        }
    }

    private func runEventLoop() {
        let mask = eventMask(for: [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .scrollWheel,
            .keyDown,
            .keyUp,
            .flagsChanged
        ])

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: inputEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lock.withLock {
                startupError = RecorderError.eventTapCreationFailed
            }
            readySemaphore.signal()
            finishedSemaphore.signal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let currentRunLoop = CFRunLoopGetCurrent()

        lock.withLock {
            eventTap = tap
            runLoop = currentRunLoop
        }

        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        readySemaphore.signal()
        CFRunLoopRun()

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
        lock.withLock {
            eventTap = nil
            runLoop = nil
        }
        finishedSemaphore.signal()
    }

    fileprivate func capture(type: CGEventType, event: CGEvent) {
        guard let recordedType = RecordedInputEvent.EventType(type) else { return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let timestamp = max(0, CMTimeGetSeconds(now - lock.withLock { startTime }))
        let hasPosition = type != .keyDown && type != .keyUp && type != .flagsChanged
        let isScroll = type == .scrollWheel
        let isKey = type == .keyDown || type == .keyUp

        let recorded = RecordedInputEvent(
            timestamp: timestamp,
            type: recordedType,
            position: hasPosition ? CodablePoint(event.location) : nil,
            buttonNumber: hasPosition && !isScroll
                ? event.getIntegerValueField(.mouseEventButtonNumber)
                : nil,
            scrollDeltaX: isScroll
                ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                : nil,
            scrollDeltaY: isScroll
                ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                : nil,
            keyCode: isKey ? event.getIntegerValueField(.keyboardEventKeycode) : nil,
            flags: event.flags.rawValue
        )

        lock.withLock {
            capturedEvents.append(recorded)
        }
    }

    private func eventMask(for types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }
}

private let inputEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<InputEventRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.capture(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private extension RecordedInputEvent.EventType {
    init?(_ type: CGEventType) {
        switch type {
        case .mouseMoved: self = .mouseMoved
        case .leftMouseDown: self = .leftMouseDown
        case .leftMouseUp: self = .leftMouseUp
        case .rightMouseDown: self = .rightMouseDown
        case .rightMouseUp: self = .rightMouseUp
        case .leftMouseDragged: self = .leftMouseDragged
        case .rightMouseDragged: self = .rightMouseDragged
        case .scrollWheel: self = .scrollWheel
        case .keyDown: self = .keyDown
        case .keyUp: self = .keyUp
        case .flagsChanged: self = .flagsChanged
        default: return nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
