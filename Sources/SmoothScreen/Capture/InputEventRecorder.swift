import ApplicationServices
import AppKit
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
    private var sourceFrameTracker: SourceFrameTracker?
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var thread: Thread?
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let finishedSemaphore = DispatchSemaphore(value: 0)
    private var startupError: Error?
    private var lastCursorStyle: RecordedInputEvent.CursorStyle?

    func start(
        at startTime: CMTime,
        source: CaptureSourceDescriptor,
        requestPermission: Bool = true
    ) throws {
        while finishedSemaphore.wait(timeout: .now()) == .success {}
        if requestPermission, !CGPreflightListenEventAccess() {
            guard CGRequestListenEventAccess() else {
                throw RecorderError.permissionDenied
            }
        }

        lock.withLock {
            capturedEvents.removeAll(keepingCapacity: true)
            self.startTime = startTime
            sourceFrameTracker = source.kind == .window
                ? SourceFrameTracker(source: source)
                : nil
            startupError = nil
            lastCursorStyle = nil
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
        let cursorTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.captureCursorAppearance()
        }
        RunLoop.current.add(cursorTimer, forMode: .common)
        captureCursorAppearance()
        CGEvent.tapEnable(tap: tap, enable: true)
        readySemaphore.signal()
        CFRunLoopRun()

        cursorTimer.invalidate()
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
        let sourceFrame = hasPosition
            ? lock.withLock { sourceFrameTracker?.frame(at: timestamp) }
            : nil
        let sampledCursorStyle = hasPosition
            ? lock.withLock { lastCursorStyle }
            : nil
        let cursorStyle: RecordedInputEvent.CursorStyle?
        switch type {
        case .leftMouseDown, .leftMouseDragged, .rightMouseDragged:
            cursorStyle = sampledCursorStyle?.draggingVariant
        default:
            cursorStyle = sampledCursorStyle
        }

        let recorded = RecordedInputEvent(
            timestamp: timestamp,
            type: recordedType,
            position: hasPosition ? CodablePoint(event.location) : nil,
            sourceFrame: sourceFrame.map(CodableRect.init),
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
            flags: event.flags.rawValue,
            cursorStyle: cursorStyle
        )

        lock.withLock {
            capturedEvents.append(recorded)
        }
    }

    private func captureCursorAppearance() {
        guard
            let cursorStyle = CursorStyleDetector.currentStyle(),
            let position = CGEvent(source: nil)?.location
        else { return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lock.withLock {
            guard cursorStyle != lastCursorStyle else { return }

            let timestamp = max(0, CMTimeGetSeconds(now - startTime))
            let sourceFrame = sourceFrameTracker?.frame(at: timestamp)
            lastCursorStyle = cursorStyle
            capturedEvents.append(RecordedInputEvent(
                timestamp: timestamp,
                type: .mouseMoved,
                position: CodablePoint(position),
                sourceFrame: sourceFrame.map(CodableRect.init),
                buttonNumber: nil,
                scrollDeltaX: nil,
                scrollDeltaY: nil,
                keyCode: nil,
                flags: 0,
                cursorStyle: cursorStyle
            ))
        }
    }

    private func eventMask(for types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }
}

private enum CursorStyleDetector {
    private static let signatures: [(Data, RecordedInputEvent.CursorStyle)] = [
        signature(for: .arrow).map { ($0, .arrow) },
        signature(for: .pointingHand).map { ($0, .pointingHand) },
        signature(for: .iBeam).map { ($0, .iBeam) },
        signature(for: .openHand).map { ($0, .openHand) },
        signature(for: .closedHand).map { ($0, .closedHand) },
        signature(for: .crosshair).map { ($0, .crosshair) },
        signature(for: .resizeLeft).map { ($0, .resizeHorizontal) },
        signature(for: .resizeRight).map { ($0, .resizeHorizontal) },
        signature(for: .resizeLeftRight).map { ($0, .resizeHorizontal) },
        signature(for: .resizeUp).map { ($0, .resizeVertical) },
        signature(for: .resizeDown).map { ($0, .resizeVertical) },
        signature(for: .resizeUpDown).map { ($0, .resizeVertical) },
        signature(for: .operationNotAllowed).map { ($0, .operationNotAllowed) },
        signature(for: .dragCopy).map { ($0, .dragCopy) },
        signature(for: .dragLink).map { ($0, .dragLink) }
    ].compactMap { $0 }

    static func currentStyle() -> RecordedInputEvent.CursorStyle? {
        guard let signature = NSCursor.currentSystem?.image.tiffRepresentation else {
            return nil
        }
        return signatures.first(where: { $0.0 == signature })?.1 ?? .arrow
    }

    private static func signature(for cursor: NSCursor) -> Data? {
        cursor.image.tiffRepresentation
    }
}

struct SourceFrameTracker {
    typealias WindowFrameLookup = (CGWindowID) -> CGRect?

    private let source: CaptureSourceDescriptor
    private let refreshInterval: Double
    private let windowFrameLookup: WindowFrameLookup
    private var cachedFrame: CGRect
    private var lastRefreshTime = -Double.infinity

    init(
        source: CaptureSourceDescriptor,
        refreshInterval: Double = 1.0 / 30.0,
        windowFrameLookup: @escaping WindowFrameLookup = SourceFrameTracker.liveWindowFrame
    ) {
        self.source = source
        self.refreshInterval = refreshInterval
        self.windowFrameLookup = windowFrameLookup
        cachedFrame = source.frame.cgRect
    }

    mutating func frame(at timestamp: Double) -> CGRect {
        guard source.kind == .window else { return cachedFrame }
        guard timestamp - lastRefreshTime >= refreshInterval else { return cachedFrame }

        lastRefreshTime = timestamp
        if let currentFrame = windowFrameLookup(CGWindowID(source.sourceID)),
           currentFrame.width > 0,
           currentFrame.height > 0 {
            cachedFrame = currentFrame
        }
        return cachedFrame
    }

    private static func liveWindowFrame(_ windowID: CGWindowID) -> CGRect? {
        guard
            let rawWindowInfo = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                windowID
            ) as? [[CFString: Any]],
            let windowInfo = rawWindowInfo.first,
            let bounds = windowInfo[kCGWindowBounds] as? NSDictionary
        else {
            return nil
        }

        return CGRect(dictionaryRepresentation: bounds)
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
