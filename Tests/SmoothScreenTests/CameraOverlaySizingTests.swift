import Foundation
import Testing
@testable import SmoothScreen

@Suite("Face camera sizing")
struct CameraOverlaySizingTests {
    @Test("Adaptive camera shrinks smoothly as the screen zooms in")
    func adaptiveSizingRespondsToZoom() {
        let settings = CameraOverlaySettings.default

        let overview = CameraOverlaySizing.size(
            settings: settings,
            cameraScale: 1,
            requiresContentClearance: false
        )
        let normalZoom = CameraOverlaySizing.size(
            settings: settings,
            cameraScale: 1.95,
            requiresContentClearance: false
        )
        let closeUp = CameraOverlaySizing.size(
            settings: settings,
            cameraScale: 2.5,
            requiresContentClearance: false
        )

        #expect(overview == 0.22)
        #expect(normalZoom < overview)
        #expect(closeUp < normalZoom)
        #expect(closeUp >= 0.12)
    }

    @Test("Adaptive camera makes extra room for an important cursor path")
    func adaptiveSizingRespondsToContentConflict() {
        let settings = CameraOverlaySettings.default
        let normal = CameraOverlaySizing.size(
            settings: settings,
            cameraScale: 2,
            requiresContentClearance: false
        )
        let clearingContent = CameraOverlaySizing.size(
            settings: settings,
            cameraScale: 2,
            requiresContentClearance: true
        )

        #expect(clearingContent < normal)
    }

    @Test("Fixed camera ignores zoom and content")
    func fixedSizingStaysConstant() {
        var settings = CameraOverlaySettings.default
        settings.sizingMode = .fixed

        let size = CameraOverlaySizing.size(
            settings: settings,
            cameraScale: 3.5,
            requiresContentClearance: true
        )

        #expect(size == settings.size)
    }

    @Test("Camera settings saved before adaptive sizing remain fixed")
    func legacySettingsRemainFixed() throws {
        let encoded = try JSONEncoder().encode(CameraOverlaySettings.default)
        var json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        json.removeValue(forKey: "sizingMode")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(
            CameraOverlaySettings.self,
            from: legacyData
        )

        #expect(decoded.sizingMode == nil)
        #expect(decoded.resolvedSizingMode == .fixed)
    }
}
