import Foundation

/// A visibility interval on the recording clock. Moving it never offsets camera footage.
struct CameraSegment: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var startTime: Double
    var endTime: Double
    var settings: CameraOverlaySettings?
}

extension RecordingProject {
    var hasCamera: Bool { recording.cameraVideoRelativePath != nil }

    var resolvedCameraSegments: [CameraSegment] {
        guard hasCamera else { return [] }
        // Absence preserves older projects; an explicitly empty array hides the camera.
        return cameraSegments ?? [CameraSegment(
            id: id, startTime: 0, endTime: max(0.1, recording.duration ?? 0.1)
        )]
    }

    /// Move a uniform older clip appearance into the global controls without changing any frames.
    /// Differing clip appearances stay intact until the user explicitly changes them.
    mutating func consolidateCameraAppearance() {
        guard let clips = cameraSegments, !clips.isEmpty,
              clips.contains(where: { $0.settings != nil }),
              var shared = clips.first.map({ $0.settings ?? resolvedCameraOverlay }), shared.isVisible,
              clips.allSatisfy({ ($0.settings ?? resolvedCameraOverlay) == shared }) else { return }
        shared.isVisible = resolvedCameraOverlay.isVisible
        cameraOverlay = shared
        cameraSegments = clips.map { clip in
            var result = clip
            result.settings = nil
            return result
        }
    }

    func cameraSegment(at time: Double) -> CameraSegment? {
        resolvedCameraSegments.first { time >= $0.startTime && time < $0.endTime }
    }

    func cameraSettings(at time: Double) -> CameraOverlaySettings? {
        guard resolvedCameraOverlay.isVisible, let segment = cameraSegment(at: time) else { return nil }
        let settings = segment.settings ?? resolvedCameraOverlay
        return settings.isVisible ? settings : nil
    }
}
