import Foundation
import Testing
@testable import Showcase

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
    @Test("Desktop backgrounds survive removal of the source and are copied into new projects")
    func remembersDesktopImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ShowcaseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Desktop.png")
        try writeBackgroundFixture(to: source)
        let cache = root.appendingPathComponent("Preferences")
        let preferences = BackgroundPreferences(defaults: defaults, directory: cache)
        try preferences.rememberImage(at: source, name: "Desktop")
        try FileManager.default.removeItem(at: source)
        let restored = BackgroundPreferences(defaults: defaults, directory: cache)
        let project = root.appendingPathComponent("New.screenproject")
        let canvas = try restored.canvasForNewRecording(in: project)
        let image = try #require(canvas.backgroundImage)
        #expect(image.name == "Desktop")
        let url = try #require(BackgroundImages.url(for: image, in: project))
        try FileManager.default.removeItem(at: cache)
        #expect(BackgroundImages.image(at: url) != nil)
        restored.remember(.ocean)
        let next = try restored.canvasForNewRecording(in: root.appendingPathComponent("Next.screenproject"))
        #expect(next.backgroundImage == nil)
        #expect(next.backgroundStartHex == BackgroundPreset.ocean.startHex)
    }

}
