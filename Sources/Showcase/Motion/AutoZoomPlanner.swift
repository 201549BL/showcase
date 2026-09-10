import CoreGraphics
import Foundation

struct AutoZoomPlanner {
    struct Configuration: Equatable {
        var scale = 1.95
        var leadTime = 0.22
        var zoomInDuration = 0.55
        var holdAfterLastClick = 1.3
        var zoomOutDuration = 0.55
        var interactionRunInterval = 1.8
        var minimumOverviewDuration = 1.25
        var overviewPaddingFraction = 0.14
        var endExclusionDuration = 0.45
    }

    // These are policy, not user-facing tuning knobs. A shot that cannot reach
    // this scale is clearer as an overview, while spatially separate actions
    // become separate shots only when there is enough time to reset the view.
    private let minimumCoherentScale = 1.3

    var configuration = Configuration()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    init(settings: ZoomBehaviorSettings) {
        configuration = Configuration(
            scale: settings.scale,
            leadTime: min(0.25, settings.transitionDuration * 0.4),
            zoomInDuration: settings.transitionDuration,
            holdAfterLastClick: settings.holdDuration,
            zoomOutDuration: settings.transitionDuration,
            interactionRunInterval: settings.groupingInterval,
            minimumOverviewDuration: settings.preset == .focused ? 0.55 : 1.25,
            overviewPaddingFraction: settings.overviewPaddingFraction,
            endExclusionDuration: 0.45
        )
    }

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
                shouldJoin(
                    click,
                    previous: previous
                )
            {
                group.append(click)
                groups[groups.count - 1] = group
            } else {
                groups.append([click])
            }
        }

        var segments: [ZoomSegment] = groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }

            let points = group.map(\.position)
            let groupScale = framingScale(points: points, sourceSize: sourceSize)
            let keepsOneComposition = groupScale >= minimumCoherentScale
            let scale = keepsOneComposition ? groupScale : configuration.scale
            let target = keepsOneComposition ? boundingCenter(points) : first.position
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
                source: .automatic,
                transitionDuration: configuration.zoomOutDuration,
                entranceDuration: max(0.001, focus - start)
            )
        }

        // A timeline block owns its complete camera lifecycle. If spatial
        // analysis split a run into two shots, make the first block finish
        // before the next begins so the timeline truthfully shows the reset.
        for index in segments.indices.dropLast() {
            let nextStart = segments[segments.index(after: index)].startTime
            if segments[index].endTime > nextStart {
                segments[index].endTime = max(segments[index].focusTime, nextStart)
            }
        }
        return segments
    }

    private func shouldJoin(
        _ click: Click,
        previous: Click
    ) -> Bool {
        let gap = click.timestamp - previous.timestamp
        if gap <= configuration.interactionRunInterval { return true }

        // A new shot is only worthwhile when the previous shot can finish and
        // leave a readable overview beat before the next entrance begins.
        let timeNeededForDistinctShot = configuration.leadTime
            + configuration.holdAfterLastClick
            + configuration.zoomOutDuration
            + configuration.minimumOverviewDuration
        return gap < timeNeededForDistinctShot
    }

    private func framingScale(points: [CGPoint], sourceSize: CGSize) -> Double {
        min(configuration.scale, fittingScale(points: points, sourceSize: sourceSize))
    }

    private func fittingScale(points: [CGPoint], sourceSize: CGSize) -> Double {
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
        return max(1, min(widthScale, heightScale))
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
