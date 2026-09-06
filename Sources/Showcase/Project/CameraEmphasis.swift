import Foundation

/// A temporary camera-bubble size animation, independent of camera visibility.
struct CameraEmphasis: Codable, Equatable, Identifiable {
    enum Source: String, Codable { case automatic, manual }

    var id = UUID()
    var startTime: Double
    var endTime: Double
    var targetSize: Double = 0.4
    var transitionDuration: Double = 0.4
    var source: Source?
    var zoomSegmentID: UUID?

    var isAutomatic: Bool { source == .automatic }

    var peakTime: Double { startTime + min(transitionDuration, (endTime - startTime) / 2) }

    func weight(at time: Double) -> Double {
        guard time.isFinite, time > startTime, time < endTime else { return 0 }
        let transition = min(max(0.01, transitionDuration), (endTime - startTime) / 2)
        let progress = min(1, min((time - startTime) / transition, (endTime - time) / transition))
        return progress * progress * progress * (progress * (progress * 6 - 15) + 10)
    }
}

extension RecordingProject {
    var resolvedCameraEmphases: [CameraEmphasis] { cameraEmphases ?? [] }

    var cameraTimelineEmphases: [CameraEmphasis] { resolvedCameraEmphases }

    /// Populate ordinary size effects from zooms. Provenance only keeps untouched defaults in sync;
    /// rendering and editing use the same effect model regardless of how an effect was created.
    mutating func synchronizeCameraEffects() {
        let existing = resolvedCameraEmphases
        let manual = existing.filter { !$0.isAutomatic }
        var effects = manual
        let excluded = Set(suppressedAutomaticCameraZoomIDs ?? []).union(manual.map(\.id))
        if hasCamera {
            for zoom in zoomSegments.sorted(by: { $0.startTime < $1.startTime }) where !excluded.contains(zoom.id) {
                var previous = existing.filter { $0.isAutomatic && ($0.zoomSegmentID ?? $0.id) == zoom.id }
                for clip in resolvedCameraSegments {
                    let settings = clip.settings ?? resolvedCameraOverlay
                    guard settings.resolvedSizingMode == .adaptive else { continue }
                    let start = max(zoom.startTime, clip.startTime)
                    let end = min(zoom.endTime, clip.endTime)
                    guard end - start >= 0.1 else { continue }
                    var gaps = [(start, end)]
                    for occupied in effects {
                        gaps = gaps.flatMap { lower, upper -> [(Double, Double)] in
                            guard occupied.startTime < upper, occupied.endTime > lower else { return [(lower, upper)] }
                            return [(lower, min(upper, occupied.startTime)), (max(lower, occupied.endTime), upper)]
                                .filter { $0.1 - $0.0 >= 0.1 }
                        }
                    }
                    for (lower, upper) in gaps {
                        let id: UUID
                        if !previous.isEmpty { id = previous.removeFirst().id }
                        else if !effects.contains(where: { $0.id == zoom.id }) { id = zoom.id }
                        else { id = UUID() }
                        effects.append(CameraEmphasis(id: id, startTime: lower, endTime: upper,
                            targetSize: CameraOverlaySizing.size(settings: settings, cameraScale: zoom.scale,
                                                                 requiresContentClearance: false),
                            transitionDuration: max(0.1, zoom.preferredEntranceDuration),
                            source: .automatic, zoomSegmentID: zoom.id))
                    }
                }
            }
        }
        if !effects.isEmpty || cameraEmphases != nil {
            cameraEmphases = effects.sorted { $0.startTime < $1.startTime }
        }
    }

    /// Once customized, retain all fragments of this zoom's defaults as independent effects.
    mutating func detachCameraEffect(id: UUID) {
        guard let effect = resolvedCameraEmphases.first(where: { $0.id == id }), effect.isAutomatic else { return }
        let zoomID = effect.zoomSegmentID ?? effect.id
        suppressedAutomaticCameraZoomIDs = Array(Set(suppressedAutomaticCameraZoomIDs ?? []).union([zoomID]))
        cameraEmphases = resolvedCameraEmphases.map { candidate in
            var candidate = candidate
            if candidate.isAutomatic && (candidate.zoomSegmentID ?? candidate.id) == zoomID {
                candidate.source = .manual
            }
            return candidate
        }
    }

    func emphasizedCameraSize(_ normalSize: Double, at time: Double) -> Double {
        let effects = resolvedCameraEmphases.sorted { $0.startTime < $1.startTime }
        guard time.isFinite, let index = effects.firstIndex(where: { time >= $0.startTime && time < $0.endTime }) else {
            return normalSize
        }
        let effect = effects[index]
        let target = min(0.6, max(0.12, effect.targetSize))
        let transition = min(max(0.01, effect.transitionDuration), (effect.endTime - effect.startTime) / 2)
        let previous = index > 0 ? effects[index - 1] : nil
        let next = index + 1 < effects.count ? effects[index + 1] : nil
        let touchesPrevious = previous.map { abs($0.endTime - effect.startTime) < 0.000_001 } ?? false
        let touchesNext = next.map { abs($0.startTime - effect.endTime) < 0.000_001 } ?? false
        // A shared edge belongs to the incoming effect's transition. The outgoing effect
        // holds its target through the edge, so adjacent sizes never dip back to normal.
        if time < effect.startTime + transition {
            let from = touchesPrevious ? min(0.6, max(0.12, previous?.targetSize ?? normalSize)) : normalSize
            return interpolateCameraSize(from, target, progress: (time - effect.startTime) / transition)
        }
        if !touchesNext && time > effect.endTime - transition {
            return interpolateCameraSize(target, normalSize, progress: (time - effect.endTime + transition) / transition)
        }
        return target
    }

    private func interpolateCameraSize(_ from: Double, _ to: Double, progress: Double) -> Double {
        let p = min(1, max(0, progress))
        let eased = p * p * p * (p * (p * 6 - 15) + 10)
        return from + (to - from) * eased
    }
}
