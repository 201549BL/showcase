import CoreGraphics
import Foundation

struct CursorPath {
    private static let maximumInterpolationGap = 0.12

    struct Keyframe: Equatable {
        let timestamp: Double
        let rawPosition: CGPoint
        let position: CGPoint
        let isClickAnchor: Bool
        let cursorStyle: RecordedInputEvent.CursorStyle
    }

    struct Frame: Equatable {
        let position: CGPoint
        let rawPosition: CGPoint
        let opacity: Double
        let cursorStyle: RecordedInputEvent.CursorStyle
    }

    let keyframes: [Keyframe]
    let hideAfter: Double
    let fadeDuration: Double

    init(
        events: [LocalizedInputEvent],
        smoothing: Double,
        hideAfter: Double,
        fadeDuration: Double = 0.2
    ) {
        let samples = events.compactMap { event -> RawSample? in
            guard event.isCursorActivity, let position = event.position else { return nil }
            return RawSample(
                timestamp: event.timestamp,
                position: position,
                isClickAnchor: event.isPrimaryClick,
                cursorStyle: Self.cursorStyle(for: event)
            )
        }

        keyframes = Self.smooth(samples: samples, amount: smoothing)
        self.hideAfter = max(0, hideAfter)
        self.fadeDuration = max(0.01, fadeDuration)
    }

    func frame(at time: Double) -> Frame? {
        guard !keyframes.isEmpty else { return nil }

        let upperIndex = keyframes.partitioningIndex { $0.timestamp > time }
        if upperIndex == 0 {
            return Frame(
                position: keyframes[0].position,
                rawPosition: keyframes[0].rawPosition,
                opacity: 0,
                cursorStyle: keyframes[0].cursorStyle
            )
        }

        let previous = keyframes[upperIndex - 1]
        let position: CGPoint
        let rawPosition: CGPoint
        if upperIndex < keyframes.count {
            let next = keyframes[upperIndex]
            let interval = next.timestamp - previous.timestamp
            if interval > 0, interval <= Self.maximumInterpolationGap {
                let progress = max(0, min(1, (time - previous.timestamp) / interval))
                position = previous.position.interpolated(to: next.position, progress: progress)
                rawPosition = previous.rawPosition.interpolated(
                    to: next.rawPosition,
                    progress: progress
                )
            } else {
                // A long event gap represents a resting cursor. Interpolating
                // toward the next event would make that movement begin too
                // early. Only let the existing smoothing lag settle to the
                // last position we actually observed.
                position = Self.settledPosition(
                    after: previous,
                    elapsed: time - previous.timestamp
                )
                rawPosition = previous.rawPosition
            }
        } else {
            position = Self.settledPosition(
                after: previous,
                elapsed: time - previous.timestamp
            )
            rawPosition = previous.rawPosition
        }

        let idleTime = max(0, time - previous.timestamp)
        let opacity: Double
        if idleTime <= hideAfter {
            opacity = 1
        } else {
            opacity = max(0, 1 - ((idleTime - hideAfter) / fadeDuration))
        }

        return Frame(
            position: position,
            rawPosition: rawPosition,
            opacity: opacity,
            cursorStyle: previous.cursorStyle
        )
    }

    private static func smooth(samples: [RawSample], amount: Double) -> [Keyframe] {
        let clampedAmount = max(0, min(1, amount))
        guard samples.count > 1, clampedAmount > 0 else {
            return rawKeyframes(for: samples)
        }

        let timeConstant = 0.015 + (0.11 * clampedAmount)
        var keyframes: [Keyframe] = []
        keyframes.reserveCapacity(samples.count)
        var burstStart = samples.startIndex

        for boundary in 1...samples.count {
            let startsNewBurst = boundary == samples.endIndex
                || samples[boundary].timestamp - samples[boundary - 1].timestamp
                    > maximumInterpolationGap
            guard startsNewBurst else { continue }

            keyframes.append(contentsOf: smoothBurst(
                Array(samples[burstStart..<boundary]),
                timeConstant: timeConstant
            ))
            burstStart = boundary
        }
        return keyframes
    }

    private static func smoothBurst(
        _ samples: [RawSample],
        timeConstant: Double
    ) -> [Keyframe] {
        guard samples.count > 1 else {
            return rawKeyframes(for: samples)
        }

        var forward = samples.map(\.position)
        var backward = samples.map(\.position)

        for index in 1..<samples.count {
            let delta = max(1.0 / 240.0, samples[index].timestamp - samples[index - 1].timestamp)
            let alpha = 1 - exp(-delta / timeConstant)
            forward[index] = forward[index - 1].interpolated(
                to: samples[index].position,
                progress: alpha
            )
        }

        for index in stride(from: samples.count - 2, through: 0, by: -1) {
            let delta = max(1.0 / 240.0, samples[index + 1].timestamp - samples[index].timestamp)
            let alpha = 1 - exp(-delta / timeConstant)
            backward[index] = backward[index + 1].interpolated(
                to: samples[index].position,
                progress: alpha
            )
        }

        let firstZeroPhase = CGPoint(
            x: (forward[0].x + backward[0].x) / 2,
            y: (forward[0].y + backward[0].y) / 2
        )
        // The backward pass can pull the first frames toward future motion.
        // Decaying its startup error with the filter's own time constant keeps
        // the burst continuous without reintroducing steady-state cursor lag.
        let initialError = CGPoint(
            x: samples[0].position.x - firstZeroPhase.x,
            y: samples[0].position.y - firstZeroPhase.y
        )

        return samples.indices.map { index in
            let sample = samples[index]
            let zeroPhase = CGPoint(
                x: (forward[index].x + backward[index].x) / 2,
                y: (forward[index].y + backward[index].y) / 2
            )
            let elapsed = max(0, sample.timestamp - samples[0].timestamp)
            let startupDecay = exp(-elapsed / timeConstant)
            let filtered = CGPoint(
                x: zeroPhase.x + (initialError.x * startupDecay),
                y: zeroPhase.y + (initialError.y * startupDecay)
            )
            return Keyframe(
                timestamp: sample.timestamp,
                rawPosition: sample.position,
                position: sample.isClickAnchor || index == samples.startIndex
                    ? sample.position
                    : filtered,
                isClickAnchor: sample.isClickAnchor,
                cursorStyle: sample.cursorStyle
            )
        }
    }

    private static func rawKeyframes(for samples: [RawSample]) -> [Keyframe] {
        samples.map {
            Keyframe(
                timestamp: $0.timestamp,
                rawPosition: $0.position,
                position: $0.position,
                isClickAnchor: $0.isClickAnchor,
                cursorStyle: $0.cursorStyle
            )
        }
    }

    private static func cursorStyle(
        for event: LocalizedInputEvent
    ) -> RecordedInputEvent.CursorStyle {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .rightMouseDragged:
            return (event.cursorStyle ?? .arrow).draggingVariant
        default:
            return event.cursorStyle ?? .arrow
        }
    }

    private static func settledPosition(
        after keyframe: Keyframe,
        elapsed: Double
    ) -> CGPoint {
        let progress = max(0, min(1, elapsed / maximumInterpolationGap))
        let easedProgress = progress * progress * (3 - (2 * progress))
        return keyframe.position.interpolated(
            to: keyframe.rawPosition,
            progress: easedProgress
        )
    }
}

private struct RawSample {
    let timestamp: Double
    let position: CGPoint
    let isClickAnchor: Bool
    let cursorStyle: RecordedInputEvent.CursorStyle
}

private extension Array {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}

extension CGPoint {
    func interpolated(to other: CGPoint, progress: Double) -> CGPoint {
        CGPoint(
            x: x + ((other.x - x) * progress),
            y: y + ((other.y - y) * progress)
        )
    }

    func distance(to other: CGPoint) -> Double {
        hypot(other.x - x, other.y - y)
    }
}
