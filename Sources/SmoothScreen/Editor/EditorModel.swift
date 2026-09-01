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
    @Published var selectedZoomID: UUID?
    @Published private(set) var playheadTime = 0.0
    @Published private(set) var undoActionName: String?
    @Published private(set) var redoActionName: String?

    let projectURL: URL
    let player = AVPlayer()

    private let projectStore: ProjectStore
    private let events: [RecordedInputEvent]
    private let localizedEvents: [LocalizedInputEvent]
    private let exporter: VideoExporter
    private var previewRefreshTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var history = EditorHistory<EditorSnapshot>()

    init(
        projectURL: URL,
        projectStore: ProjectStore = ProjectStore(),
        exporter: VideoExporter = VideoExporter()
    ) throws {
        self.projectURL = projectURL
        self.projectStore = projectStore
        self.exporter = exporter
        let loadedProject = try projectStore.loadProject(at: projectURL)
        let loadedEvents = try projectStore.loadEvents(at: projectURL)
        project = loadedProject
        events = loadedEvents
        localizedEvents = InputEventLocalizer().localize(
            loadedEvents,
            source: loadedProject.recording.source,
            pixelWidth: loadedProject.recording.width,
            pixelHeight: loadedProject.recording.height
        )
        selectedZoomID = loadedProject.zoomSegments.first?.id
        rebuildPreview(preservingTime: false)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.playheadTime = max(0, CMTimeGetSeconds(time))
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
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

    var clickTimestamps: [Double] {
        localizedEvents.filter(\.isPrimaryClick).map(\.timestamp)
    }

    var selectedZoom: ZoomSegment? {
        guard let selectedZoomID else { return nil }
        return project.zoomSegments.first { $0.id == selectedZoomID }
    }

    var zoomBehavior: ZoomBehaviorSettings {
        project.resolvedZoomBehavior
    }

    var canUndo: Bool { undoActionName != nil }
    var canRedo: Bool { redoActionName != nil }

    func setTrimStart(_ value: Double) {
        let latestStart = trimEnd - 0.1
        editProject(actionName: "Trim Start") { project in
            if project.timeline == nil { project.timeline = .default }
            project.timeline?.trimStart = min(max(0, value), latestStart)
        }
    }

    func setTrimEnd(_ value: Double) {
        let earliestEnd = trimStart + 0.1
        let duration = recordingDuration
        editProject(actionName: "Trim End") { project in
            if project.timeline == nil { project.timeline = .default }
            project.timeline?.trimEnd = max(earliestEnd, min(duration, value))
        }
    }

    func setQuality(_ value: ExportQuality) {
        performHistoryEdit(actionName: "Change Quality") {
            quality = value
        }
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
        let automatic = plannedAutomaticZooms(settings: zoomBehavior)
        editProject(actionName: "Regenerate Zooms") { project in
            project.zoomSegments = (automatic + manual).sorted { $0.startTime < $1.startTime }
        }
        if selectedZoom == nil {
            selectedZoomID = project.zoomSegments.first?.id
        }
    }

    func applyZoomPreset(_ preset: ZoomBehaviorSettings.Preset) {
        let settings = zoomBehavior.applying(preset)
        let manual = project.zoomSegments.filter { $0.source == .manual }
        let automatic = plannedAutomaticZooms(settings: settings)
        editProject(actionName: "Apply \(preset.displayName) Zooms") { project in
            project.zoomBehavior = settings
            project.zoomSegments = (automatic + manual).sorted { $0.startTime < $1.startTime }
        }
        if selectedZoom == nil {
            selectedZoomID = project.zoomSegments.first?.id
        }
    }

    func updateCustomZoomBehavior(
        _ keyPath: WritableKeyPath<ZoomBehaviorSettings, Double>,
        value: Double,
        actionName: String
    ) {
        editProject(actionName: actionName, rebuildPreview: false) { project in
            var settings = project.resolvedZoomBehavior
            settings.preset = .custom
            settings[keyPath: keyPath] = value
            project.zoomBehavior = settings
        }
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
        editProject(actionName: "Add Zoom") { project in
            project.zoomSegments.append(segment)
            project.zoomSegments.sort { $0.startTime < $1.startTime }
        }
        selectedZoomID = segment.id
        seek(to: segment.focusTime)
    }

    func deleteZoom(id: UUID) {
        editProject(actionName: "Delete Zoom") { project in
            project.zoomSegments.removeAll { $0.id == id }
        }
        if selectedZoomID == id { selectedZoomID = nil }
    }

    func selectZoom(id: UUID, seekToFocus: Bool = true) {
        selectedZoomID = id
        guard
            seekToFocus,
            let zoom = project.zoomSegments.first(where: { $0.id == id })
        else { return }
        seek(to: zoom.focusTime)
    }

    func seek(to time: Double) {
        let seconds = min(trimEnd, max(trimStart, time))
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        playheadTime = seconds
    }

    func moveZoom(id: UUID, toStart proposedStart: Double) {
        guard let index = project.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        let duration = project.zoomSegments[index].endTime
            - project.zoomSegments[index].startTime
        let focusOffset = project.zoomSegments[index].focusTime
            - project.zoomSegments[index].startTime
        let start = min(max(0, proposedStart), max(0, recordingDuration - duration))
        project.zoomSegments[index].startTime = start
        project.zoomSegments[index].focusTime = min(start + duration, start + focusOffset)
        project.zoomSegments[index].endTime = start + duration
    }

    func resizeZoomStart(id: UUID, to proposedStart: Double) {
        guard let index = project.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        let latest = project.zoomSegments[index].endTime - 0.1
        let start = min(max(0, proposedStart), latest)
        project.zoomSegments[index].startTime = start
        project.zoomSegments[index].focusTime = max(
            start,
            project.zoomSegments[index].focusTime
        )
    }

    func resizeZoomEnd(id: UUID, to proposedEnd: Double) {
        guard let index = project.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        let earliest = project.zoomSegments[index].startTime + 0.1
        let end = max(earliest, min(recordingDuration, proposedEnd))
        project.zoomSegments[index].endTime = end
        project.zoomSegments[index].focusTime = min(
            end,
            project.zoomSegments[index].focusTime
        )
    }

    func commitTimelineEdit() {
        project.zoomSegments.sort { $0.startTime < $1.startTime }
        projectDidChange()
        commitHistoryTransaction()
    }

    func setSelectedZoomFocus(_ point: CGPoint) {
        guard
            let selectedZoomID,
            let index = project.zoomSegments.firstIndex(where: { $0.id == selectedZoomID })
        else { return }

        let scale = max(1, project.zoomSegments[index].scale)
        let halfWidth = Double(project.recording.width) / (2 * scale)
        let halfHeight = Double(project.recording.height) / (2 * scale)
        editProject(actionName: "Set Zoom Focus") { project in
            project.zoomSegments[index].focusPoint = CodablePoint(CGPoint(
                x: min(Double(project.recording.width) - halfWidth, max(halfWidth, point.x)),
                y: min(Double(project.recording.height) - halfHeight, max(halfHeight, point.y))
            ))
        }
    }

    func applyBackground(_ preset: BackgroundPreset) {
        editProject(actionName: "Change Background") { project in
            project.canvas.backgroundStartHex = preset.startHex
            project.canvas.backgroundEndHex = preset.endHex
        }
    }

    func beginHistoryTransaction(actionName: String) {
        history.begin(snapshot: historySnapshot, actionName: actionName)
    }

    func commitHistoryTransaction() {
        history.commit(current: historySnapshot)
        syncHistoryState()
    }

    func editProject(
        actionName: String,
        rebuildPreview: Bool = true,
        _ edit: (inout RecordingProject) -> Void
    ) {
        performHistoryEdit(actionName: actionName) {
            edit(&project)
        }
        projectDidChange(rebuildPreview: rebuildPreview)
    }

    func undo() {
        if history.hasActiveTransaction {
            commitHistoryTransaction()
        }
        guard let snapshot = history.undo(current: historySnapshot) else { return }
        restore(snapshot)
    }

    func redo() {
        if history.hasActiveTransaction {
            commitHistoryTransaction()
        }
        guard let snapshot = history.redo(current: historySnapshot) else { return }
        restore(snapshot)
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

    private func plannedAutomaticZooms(settings: ZoomBehaviorSettings) -> [ZoomSegment] {
        guard settings.preset != .off else { return [] }
        return AutoZoomPlanner(settings: settings).plan(
            events: localizedEvents,
            sourceSize: CGSize(width: project.recording.width, height: project.recording.height),
            duration: project.recording.duration ?? 0
        )
    }

    private var historySnapshot: EditorSnapshot {
        EditorSnapshot(project: project, quality: quality)
    }

    private func performHistoryEdit(actionName: String, edit: () -> Void) {
        let ownsTransaction = !history.hasActiveTransaction
        if ownsTransaction {
            beginHistoryTransaction(actionName: actionName)
        }
        edit()
        if ownsTransaction {
            commitHistoryTransaction()
        }
    }

    private func restore(_ snapshot: EditorSnapshot) {
        project = snapshot.project
        quality = snapshot.quality
        if let selectedZoomID, !project.zoomSegments.contains(where: { $0.id == selectedZoomID }) {
            self.selectedZoomID = project.zoomSegments.first?.id
        } else if selectedZoomID == nil {
            selectedZoomID = project.zoomSegments.first?.id
        }
        syncHistoryState()
        projectDidChange()
    }

    private func syncHistoryState() {
        undoActionName = history.undoActionName
        redoActionName = history.redoActionName
    }
}

private struct EditorSnapshot: Equatable {
    let project: RecordingProject
    let quality: ExportQuality
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
