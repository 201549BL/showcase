import Foundation

struct BackgroundPreferences {
    private let defaults: UserDefaults
    private let directory: URL
    private let key = "SmoothScreen.lastBackgroundPreset"
    private let imageKey = "Showcase.lastBackgroundImageName"

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Showcase/BackgroundPreferences", isDirectory: true)
    }

    func remember(_ preset: BackgroundPreset) {
        defaults.set(preset.rawValue, forKey: key)
        defaults.removeObject(forKey: imageKey)
    }

    func rememberImage(at url: URL, name: String) throws {
        let data = try Data(contentsOf: url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("background.png"), options: .atomic)
        defaults.set(name, forKey: imageKey)
    }

    var canvasForNewRecording: CanvasSettings {
        var canvas = CanvasSettings.default
        if let name = defaults.string(forKey: key), let preset = BackgroundPreset(rawValue: name) {
            canvas.backgroundStartHex = preset.startHex
            canvas.backgroundEndHex = preset.endHex
        }
        return canvas
    }

    func canvasForNewRecording(in projectURL: URL) throws -> CanvasSettings {
        var canvas = canvasForNewRecording
        let imageURL = directory.appendingPathComponent("background.png")
        if let name = defaults.string(forKey: imageKey), FileManager.default.fileExists(atPath: imageURL.path) {
            canvas.backgroundImage = try BackgroundImages.importImage(at: imageURL, into: projectURL, name: name)
        }
        return canvas
    }
}
