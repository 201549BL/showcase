import CoreGraphics
import Foundation

struct AutoZoomPlanner {
    struct Configuration: Equatable {
        var scale = 1.6
        var leadTime = 0.2
        var zoomInDuration = 0.4
        var holdAfterLastClick = 0.9
        var zoomOutDuration = 0.5
        var interactionRunInterval = 1.6
        var overviewPaddingFraction = 0.12
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

        var groups: [[Click]] = []

        for click in clicks {
            if
                var group = groups.last,
                let previous = group.last,
                click.timestamp - previous.timestamp <= configuration.interactionRunInterval
            {
                group.append(click)
                groups[groups.count - 1] = group
            } else {
                groups.append([click])
            }
        }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }

            let points = group.map(\.position)
            let scale = framingScale(points: points, sourceSize: sourceSize)
            let target = scale < configuration.scale - 0.001
                ? boundingCenter(points)
                : weightedFocusPoint(points)
            let clampedTarget = clampedFocus(
                target,
                sourceSize: sourceSize,
                scale: scale
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
                scale: scale,
                source: .automatic
            )
        }
    }

    private func framingScale(points: [CGPoint], sourceSize: CGSize) -> Double {
        guard let first = points.first else { return 1 }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let paddedWidth = (maxX - minX)
            + (2 * sourceSize.width * configuration.overviewPaddingFraction)
        let paddedHeight = (maxY - minY)
            + (2 * sourceSize.height * configuration.overviewPaddingFraction)
        let widthScale = sourceSize.width / max(1, paddedWidth)
        let heightScale = sourceSize.height / max(1, paddedHeight)
        return max(1, min(configuration.scale, widthScale, heightScale))
    }

    private func boundingCenter(_ points: [CGPoint]) -> CGPoint {
        guard let first = points.first else { return .zero }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
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
