import Foundation
import Testing
@testable import SmoothScreen

@Suite("Background preferences")
struct BackgroundPreferencesTests {
    @Test("New recordings reuse the last background across preference instances")
    func remembersBackground() throws {
        let suite = "SmoothScreenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BackgroundPreferences(defaults: defaults)
        #expect(preferences.canvasForNewRecording == .default)
        preferences.remember(.ocean)
        let restored = BackgroundPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        let canvas = restored.canvasForNewRecording
        #expect(canvas.backgroundStartHex == BackgroundPreset.ocean.startHex)
        #expect(canvas.backgroundEndHex == BackgroundPreset.ocean.endHex)
        #expect(canvas.padding == CanvasSettings.default.padding)
        preferences.remember(.moss)
        #expect(restored.canvasForNewRecording.backgroundStartHex == BackgroundPreset.moss.startHex)
    }
}
