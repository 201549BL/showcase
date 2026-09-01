import CoreGraphics
import Foundation

struct CursorPath {
    struct Keyframe: Equatable {
        let timestamp: Double
        let rawPosition: CGPoint
        let position: CGPoint
        let isClickAnchor: Bool
    }

    struct Frame: Equatable {
        let position: CGPoint
        let opacity: Double
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
                isClickAnchor: event.isPrimaryClick
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
            return Frame(position: keyframes[0].position, opacity: 0)
        }

        let previous = keyframes[upperIndex - 1]
        let position: CGPoint
        if upperIndex < keyframes.count {
            let next = keyframes[upperIndex]
            let interval = next.timestamp - previous.timestamp
            let progress = interval > 0 ? max(0, min(1, (time - previous.timestamp) / interval)) : 0
            position = previous.position.interpolated(to: next.position, progress: progress)
        } else {
            position = previous.position
        }

        let idleTime = max(0, time - previous.timestamp)
        let opacity: Double
        if idleTime <= hideAfter {
            opacity = 1
        } else {
            opacity = max(0, 1 - ((idleTime - hideAfter) / fadeDuration))
        }

        return Frame(position: position, opacity: opacity)
    }

    private static func smooth(samples: [RawSample], amount: Double) -> [Keyframe] {
        guard samples.count > 1 else {
            return samples.map {
                Keyframe(
                    timestamp: $0.timestamp,
                    rawPosition: $0.position,
                    position: $0.position,
                    isClickAnchor: $0.isClickAnchor
                )
            }
        }

        let clampedAmount = max(0, min(1, amount))
        guard clampedAmount > 0 else {
            return samples.map {
                Keyframe(
                    timestamp: $0.timestamp,
                    rawPosition: $0.position,
                    position: $0.position,
                    isClickAnchor: $0.isClickAnchor
                )
            }
        }

        let timeConstant = 0.015 + (0.11 * clampedAmount)
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

        return samples.indices.map { index in
            let sample = samples[index]
            let filtered = CGPoint(
                x: (forward[index].x + backward[index].x) / 2,
                y: (forward[index].y + backward[index].y) / 2
            )
            return Keyframe(
                timestamp: sample.timestamp,
                rawPosition: sample.position,
                position: sample.isClickAnchor ? sample.position : filtered,
                isClickAnchor: sample.isClickAnchor
            )
        }
    }
}

private struct RawSample {
    let timestamp: Double
    let position: CGPoint
    let isClickAnchor: Bool
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
