import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    @Published var project: RecordingProject
    @Published var quality: ExportQuality = .hd
    @Published private(set) var isExporting = false
    @Published private(set) var lastExportURL: URL?
    @Published var presentedError: PresentedError?

    let projectURL: URL
    let player = AVPlayer()

    private let projectStore: ProjectStore
    private let events: [RecordedInputEvent]
    private let exporter: VideoExporter
    private var previewRefreshTask: Task<Void, Never>?

    init(
        projectURL: URL,
        projectStore: ProjectStore = ProjectStore(),
        exporter: VideoExporter = VideoExporter()
    ) throws {
        self.projectURL = projectURL
        self.projectStore = projectStore
        self.exporter = exporter
        project = try projectStore.loadProject(at: projectURL)
        events = try projectStore.loadEvents(at: projectURL)
        rebuildPreview(preservingTime: false)
    }

    var canvasAspectRatio: Double {
        let geometry = CanvasGeometry(project: project, quality: quality)
        return geometry.canvasSize.width / geometry.canvasSize.height
    }

    var recordingDuration: Double {
        max(0.1, project.recording.duration ?? 0.1)
    }

    var trimStart: Double {
        project.timeline?.trimStart ?? 0
    }

    var trimEnd: Double {
        project.timeline?.trimEnd ?? recordingDuration
    }

    func setTrimStart(_ value: Double) {
        if project.timeline == nil { project.timeline = .default }
        project.timeline?.trimStart = min(max(0, value), trimEnd - 0.1)
        projectDidChange()
    }

    func setTrimEnd(_ value: Double) {
        if project.timeline == nil { project.timeline = .default }
        project.timeline?.trimEnd = max(trimStart + 0.1, min(recordingDuration, value))
        projectDidChange()
    }

    func projectDidChange(rebuildPreview: Bool = true) {
        do {
            try projectStore.save(project, to: projectStore.locations(for: projectURL))
        } catch {
            present(error)
            return
        }

        guard rebuildPreview else { return }
        previewRefreshTask?.cancel()
        previewRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.rebuildPreview(preservingTime: true)
        }
    }

    func regenerateAutomaticZooms() {
        let manual = project.zoomSegments.filter { $0.source == .manual }
        let localized = InputEventLocalizer().localize(
            events,
            source: project.recording.source,
            pixelWidth: project.recording.width,
            pixelHeight: project.recording.height
        )
        let automatic = AutoZoomPlanner().plan(
            events: localized,
            sourceSize: CGSize(width: project.recording.width, height: project.recording.height),
            duration: project.recording.duration ?? 0
        )
        project.zoomSegments = (automatic + manual).sorted { $0.startTime < $1.startTime }
        projectDidChange()
    }

    func addManualZoom() {
        let time = max(0, CMTimeGetSeconds(player.currentTime()))
        let duration = project.recording.duration ?? time + 2
        let start = max(0, time - 0.25)
        let end = min(duration, time + 1.75)
        let segment = ZoomSegment(
            id: UUID(),
            startTime: start,
            focusTime: min(end, time + 0.25),
            endTime: end,
            focusPoint: CodablePoint(
                CGPoint(
                    x: Double(project.recording.width) / 2,
                    y: Double(project.recording.height) / 2
                )
            ),
            scale: 1.6,
            source: .manual
        )
        project.zoomSegments.append(segment)
        project.zoomSegments.sort { $0.startTime < $1.startTime }
        projectDidChange()
    }

    func deleteZoom(id: UUID) {
        project.zoomSegments.removeAll { $0.id == id }
        projectDidChange()
    }

    func applyBackground(_ preset: BackgroundPreset) {
        project.canvas.backgroundStartHex = preset.startHex
        project.canvas.backgroundEndHex = preset.endHex
        projectDidChange()
    }

    func exportVideo() async {
        let panel = NSSavePanel()
        panel.title = "Export SmoothScreen Video"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = projectURL.deletingPathExtension().lastPathComponent + ".mp4"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        player.pause()
        defer { isExporting = false }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try await exporter.export(
                projectURL: projectURL,
                destinationURL: destination,
                quality: quality
            )
            lastExportURL = destination
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            present(error)
        }
    }

    func revealProject() {
        NSWorkspace.shared.activateFileViewerSelecting([projectURL])
    }

    func revealLastExport() {
        guard let lastExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
    }

    private func rebuildPreview(preservingTime: Bool) {
        let currentTime = preservingTime ? player.currentTime() : .zero
        let wasPlaying = player.rate != 0
        let locations = projectStore.locations(for: projectURL)
        let asset = AVURLAsset(url: locations.videoURL)
        let built = VideoCompositionBuilder().build(
            asset: asset,
            project: project,
            events: events,
            quality: quality
        )
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = built.composition
        item.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        player.replaceCurrentItem(with: item)
        let requestedSeconds = CMTimeGetSeconds(currentTime)
        let seekSeconds = min(trimEnd, max(trimStart, requestedSeconds.isFinite ? requestedSeconds : trimStart))
        player.seek(
            to: CMTime(seconds: seekSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        if wasPlaying { player.play() }
    }

    private func present(_ error: Error) {
        presentedError = PresentedError(
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
    }
}

enum BackgroundPreset: String, CaseIterable, Identifiable {
    case violet
    case ocean
    case sunset
    case graphite
    case moss

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var startHex: String {
        switch self {
        case .violet: return "#5B4BE8"
        case .ocean: return "#075985"
        case .sunset: return "#E94B4B"
        case .graphite: return "#171717"
        case .moss: return "#315C45"
        }
    }

    var endHex: String {
        switch self {
        case .violet: return "#C76BFF"
        case .ocean: return "#38BDF8"
        case .sunset: return "#FDBA74"
        case .graphite: return "#525252"
        case .moss: return "#A3C585"
        }
    }
}
