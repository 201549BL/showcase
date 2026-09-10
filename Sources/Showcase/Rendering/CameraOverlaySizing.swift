import Foundation

enum CameraOverlaySizing {
    static func size(
        settings: CameraOverlaySettings,
        cameraScale: Double,
        requiresContentClearance: Bool
    ) -> Double {
        guard settings.resolvedSizingMode == .adaptive else { return settings.size }
        let maximumSize = min(0.6, max(0.12, settings.size))

        let zoomProgress = smootherStep(
            min(1, max(0, (cameraScale - 1) / 0.8))
        )
        // A modest diameter change preserves the speaker's presence during content zooms.
        let zoomReduction = 0.15 * zoomProgress
        let clearanceReduction = requiresContentClearance ? 0.05 * zoomProgress : 0
        return max(0.12, maximumSize * (1 - zoomReduction - clearanceReduction))
    }

    private static func smootherStep(_ value: Double) -> Double {
        value * value * value * (value * (value * 6 - 15) + 10)
    }
}
