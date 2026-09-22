import Foundation

struct CursorPreferences {
    private let defaults: UserDefaults
    private let key = "Showcase.lastCursorSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settingsForNewRecording: CursorSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CursorSettings.self, from: data)
        else { return .default }
        return settings
    }

    func remember(_ settings: CursorSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
