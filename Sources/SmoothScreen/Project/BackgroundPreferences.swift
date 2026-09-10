import Foundation

struct BackgroundPreferences {
    private let defaults: UserDefaults
    private let key = "SmoothScreen.lastBackgroundPreset"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func remember(_ preset: BackgroundPreset) {
        defaults.set(preset.rawValue, forKey: key)
    }

    var canvasForNewRecording: CanvasSettings {
        var canvas = CanvasSettings.default
        if let name = defaults.string(forKey: key), let preset = BackgroundPreset(rawValue: name) {
            canvas.backgroundStartHex = preset.startHex
            canvas.backgroundEndHex = preset.endHex
        }
        return canvas
    }
}
