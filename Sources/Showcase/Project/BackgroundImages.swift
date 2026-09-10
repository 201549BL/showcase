import AppKit
import ImageIO
import UniformTypeIdentifiers

struct BackgroundImageAsset: Codable, Equatable {
    var relativePath: String
    var name: String
}

/// Resolves images once when a composition is built, never on the per-frame render path.
enum BackgroundImages {
    enum ImageError: LocalizedError {
        case unreadable
        var errorDescription: String? {
            "This image could not be opened. Choose a JPEG, PNG, HEIC, or another supported still image."
        }
    }

    static func image(at url: URL, maximumDimension: Int = 3_840) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func importImage(at url: URL, into projectURL: URL, name: String? = nil) throws -> BackgroundImageAsset {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let image = image(at: url) else { throw ImageError.unreadable }
        let asset = BackgroundImageAsset(
            relativePath: "media/backgrounds/\(UUID().uuidString).png",
            name: name ?? url.deletingPathExtension().lastPathComponent
        )
        let destinationURL = projectURL.appendingPathComponent(asset.relativePath)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ImageError.unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.unreadable }
        try (data as Data).write(to: destinationURL, options: .atomic)
        return asset
    }

    static func url(for asset: BackgroundImageAsset?, in projectURL: URL?) -> URL? {
        guard let asset, let projectURL else { return nil }
        let root = projectURL.standardizedFileURL
        let url = root.appendingPathComponent(asset.relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }
}

struct DesktopWallpaper: Identifiable {
    let url: URL
    let name: String
    let thumbnail: NSImage
    var id: String { url.path }

    @MainActor
    static func available() async -> [DesktopWallpaper] {
        let current = NSScreen.screens.compactMap { screen -> (URL, String)? in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return (url, "Desktop · \(screen.localizedName)")
        }
        return await Task.detached(priority: .userInitiated) { load(current: current) }.value
    }

    private static func load(current: [(URL, String)]) -> [DesktopWallpaper] {
        var candidates = current
        let extensions = Set(["heic", "heif", "jpg", "jpeg", "png", "tiff"])
        for directory in ["/System/Library/Desktop Pictures", "/Library/Desktop Pictures"] {
            guard let files = FileManager.default.enumerator(
                at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var installed: [URL] = []
            for case let url as URL in files where extensions.contains(url.pathExtension.lowercased()) {
                installed.append(url)
            }
            candidates += installed.sorted {
                let firstIsSolid = $0.deletingLastPathComponent().lastPathComponent == "Solid Colors"
                let secondIsSolid = $1.deletingLastPathComponent().lastPathComponent == "Solid Colors"
                if firstIsSolid != secondIsSolid { return !firstIsSolid }
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
                .map { ($0, $0.deletingPathExtension().lastPathComponent) }
        }
        var seen = Set<String>()
        return candidates.compactMap { url, name in
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted,
                  let image = BackgroundImages.image(at: url, maximumDimension: 320) else { return nil }
            return DesktopWallpaper(url: url, name: name, thumbnail: NSImage(cgImage: image, size: .zero))
        }
    }
}
