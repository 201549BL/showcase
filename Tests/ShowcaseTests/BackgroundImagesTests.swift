import CoreImage
import Foundation
import Testing
@testable import Showcase

@Suite("Background images")
struct BackgroundImagesTests {
    @Test("Imported backgrounds remain usable after the original is deleted and the project moves")
    func portableImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Picture.png")
        try writeBackgroundFixture(to: original)
        let project = root.appendingPathComponent("Original.screenproject")
        let asset = try BackgroundImages.importImage(at: original, into: project)
        try FileManager.default.removeItem(at: original)
        let moved = root.appendingPathComponent("Moved.screenproject")
        try FileManager.default.moveItem(at: project, to: moved)
        let url = try #require(BackgroundImages.url(for: asset, in: moved))
        #expect(BackgroundImages.image(at: url) != nil)
        #expect(asset.name == "Picture")
        var settings = CanvasSettings.default
        settings.backgroundImage = asset
        let decoded = try JSONDecoder().decode(CanvasSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test("Older projects retain their gradient and invalid image files are rejected")
    func compatibilityAndValidation() throws {
        let encoded = try JSONEncoder().encode(CanvasSettings.default)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "backgroundImage")
        let decoded = try JSONDecoder().decode(CanvasSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == CanvasSettings.default)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        #expect(throws: BackgroundImages.ImageError.self) {
            try BackgroundImages.importImage(at: invalid, into: root)
        }
    }
}

func writeBackgroundFixture(to url: URL) throws {
    let image = CIImage(color: .green).cropped(to: CGRect(x: 75, y: 0, width: 250, height: 100))
        .composited(over: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 100)))
    try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}
