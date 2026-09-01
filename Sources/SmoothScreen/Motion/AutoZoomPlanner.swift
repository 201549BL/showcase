import CoreGraphics
import Foundation

struct AutoZoomPlanner {
    struct Configuration: Equatable {
        var scale = 1.6
        var leadTime = 0.2
        var zoomInDuration = 0.4
        var holdAfterLastClick = 0.9
        var zoomOutDuration = 0.5
        var mergeTimeInterval = 1.5
        var mergeDistanceFraction = 0.18
        var endExclusionDuration = 0.45
    }

    var configuration = Configuration()

    func plan(
        events: [LocalizedInputEvent],
        sourceSize: CGSize,
        duration: Double
    ) -> [ZoomSegment] {
        guard sourceSize.width > 0, sourceSize.height > 0, duration > 0 else { return [] }

        let endCutoff = duration > configuration.endExclusionDuration
            ? duration - configuration.endExclusionDuration
            : duration
        let clicks = events.compactMap { event -> Click? in
            guard
                event.isPrimaryClick,
                event.timestamp <= endCutoff,
                let position = event.position
            else { return nil }
            return Click(timestamp: event.timestamp, position: position)
        }.sorted { $0.timestamp < $1.timestamp }

        guard !clicks.isEmpty else { return [] }

        let mergeDistance = max(sourceSize.width, sourceSize.height)
            * configuration.mergeDistanceFraction
        var groups: [[Click]] = []

        for click in clicks {
            if
                var group = groups.last,
                let previous = group.last,
                click.timestamp - previous.timestamp <= configuration.mergeTimeInterval,
                click.position.distance(to: previous.position) <= mergeDistance
            {
                group.append(click)
                groups[groups.count - 1] = group
            } else {
                groups.append([click])
            }
        }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }

            let target = weightedFocusPoint(group.map(\.position))
            let clampedTarget = clampedFocus(
                target,
                sourceSize: sourceSize,
                scale: configuration.scale
            )
            let start = max(0, first.timestamp - configuration.leadTime)
            let focus = min(duration, first.timestamp + configuration.zoomInDuration)
            let end = min(
                duration,
                last.timestamp + configuration.holdAfterLastClick + configuration.zoomOutDuration
            )

            guard end - start >= 0.15 else { return nil }
            return ZoomSegment(
                id: UUID(),
                startTime: start,
                focusTime: max(start, focus),
                endTime: max(focus, end),
                focusPoint: CodablePoint(clampedTarget),
                scale: configuration.scale,
                source: .automatic
            )
        }
    }

    private func weightedFocusPoint(_ points: [CGPoint]) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard points.count > 1 else { return first }

        var weightedX = 0.0
        var weightedY = 0.0
        var totalWeight = 0.0
        for (index, point) in points.enumerated() {
            let weight = Double(index + 1)
            weightedX += point.x * weight
            weightedY += point.y * weight
            totalWeight += weight
        }
        return CGPoint(x: weightedX / totalWeight, y: weightedY / totalWeight)
    }

    private func clampedFocus(_ point: CGPoint, sourceSize: CGSize, scale: Double) -> CGPoint {
        let safeScale = max(1, scale)
        let halfViewportWidth = sourceSize.width / (2 * safeScale)
        let halfViewportHeight = sourceSize.height / (2 * safeScale)
        return CGPoint(
            x: min(sourceSize.width - halfViewportWidth, max(halfViewportWidth, point.x)),
            y: min(sourceSize.height - halfViewportHeight, max(halfViewportHeight, point.y))
        )
    }
}

private struct Click {
    let timestamp: Double
    let position: CGPoint
}
