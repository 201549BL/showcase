import Foundation
import Testing
@testable import Showcase

struct CursorPreferencesTests {
    @Test("New recordings remember cursor customization across preference instances")
    func remembersCustomization() throws {
        let suite = "ShowcaseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CursorPreferences(defaults: defaults)
        #expect(preferences.settingsForNewRecording == .default)
        var settings = CursorSettings.default
        settings.theme = .capitaine
        settings.fillHex = "#FF8300"
        settings.outlineHex = "#663399"
        settings.scale = 2
        preferences.remember(settings)
        let restored = CursorPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(restored.settingsForNewRecording == settings)
        preferences.remember(.default)
        #expect(restored.settingsForNewRecording == .default)
    }

    @Test("Invalid saved preferences fall back to usable defaults")
    func invalidPreferences() throws {
        let suite = "ShowcaseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: "Showcase.lastCursorSettings")
        #expect(CursorPreferences(defaults: defaults).settingsForNewRecording == .default)
    }
}
