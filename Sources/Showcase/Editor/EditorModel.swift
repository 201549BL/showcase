import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    @Published var project: RecordingProject
    @Published private(set) var hasAudio = false
    @Published var quality: ExportQuality = .hd
    @Published private(set) var isExporting = false
    @Published private(set) var lastExportURL: URL?
    @Published var presentedError: PresentedError?
    @Published var selectedZoomID: UUID? {
        didSet {
            if selectedZoomID != nil { selectedCameraID = nil; selectedCameraEmphasisID = nil }
        }
    }
    @Published var selectedCameraID: UUID? {
        didSet {
            if selectedCameraID != nil { selectedZoomID = nil; selectedReframeID = nil; selectedCameraEmphasisID = nil }
        }
    }
    @Published var selectedCameraEmphasisID: UUID? {
        didSet {
            if selectedCameraEmphasisID != nil { selectedZoomID = nil; selectedCameraID = nil; selectedReframeID = nil }
        }
    }
    @Published var selectedReframeID: UUID?
    @Published private(set) var playheadTime = 0.0
    @Published private(set) var isPlaying = false
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
    private var playbackObservation: NSKeyValueObservation?
    private var history = EditorHistory<EditorSnapshot>()
    private var isEditingViewbox = false

    init(
        projectURL: URL,
        projectStore: ProjectStore = ProjectStore(),
        exporter: VideoExporter = VideoExporter()
    ) throws {
        self.projectURL = projectURL
        self.projectStore = projectStore
        self.exporter = exporter
        var loadedProject = try projectStore.loadProject(at: projectURL)
        loadedProject.consolidateCameraAppearance()
        for index in loadedProject.zoomSegments.indices {
            loadedProject.zoomSegments[index].normalizeTiming()
        }
        loadedProject.synchronizeCameraEffects()
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
        playbackObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor [weak self] in self?.isPlaying = playing }
        }
        rebuildPreview(preservingTime: false)
        let asset = AVURLAsset(url: projectStore.locations(for: projectURL).videoURL)
        Task { [weak self] in
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                self?.hasAudio = !tracks.isEmpty
            } catch {
                self?.present(error)
            }
        }
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

    var selectedReframe: ZoomReframe? {
        guard let selectedReframeID else { return nil }
        return selectedZoom?.reframes.first { $0.id == selectedReframeID }
    }

    var selectedViewboxTarget: ZoomViewboxEditTarget? {
        guard let selectedZoom else { return nil }
        if let selectedReframe {
            return ZoomViewboxEditTarget(
                id: selectedReframe.id,
                focusPoint: selectedReframe.focusPoint.cgPoint,
                scale: selectedReframe.scale,
                time: selectedReframe.time,
                cursorBoundaryFraction: selectedZoom.resolvedCursorBoundaryFraction
            )
        }
        return ZoomViewboxEditTarget(
            id: selectedZoom.id,
            focusPoint: selectedZoom.focusPoint.cgPoint,
            scale: selectedZoom.scale,
            time: selectedZoom.focusTime,
            cursorBoundaryFraction: selectedZoom.resolvedCursorBoundaryFraction
        )
    }

    func cameraPositions(for zoom: ZoomSegment) -> [ZoomCameraPosition] {
        let initial = ZoomCameraPosition(
            id: zoom.id,
            time: zoom.focusTime,
            focusPoint: zoom.focusPoint.cgPoint,
            scale: zoom.scale,
            isInitial: true
        )
        let later = zoom.reframes.map {
            ZoomCameraPosition(
                id: $0.id,
                time: $0.time,
                focusPoint: $0.focusPoint.cgPoint,
                scale: $0.scale,
                isInitial: false
            )
        }
        return ([initial] + later).sorted { $0.time < $1.time }
    }

    var zoomBehavior: ZoomBehaviorSettings {
        project.resolvedZoomBehavior
    }

    var canUndo: Bool { undoActionName != nil }
    var canRedo: Bool { redoActionName != nil }

    var isTrimmed: Bool {
        trimStart > 0.000_001 || trimEnd < recordingDuration - 0.000_001
    }

    func resetTrim() {
        let duration = recordingDuration
        editProject(actionName: "Reset Trim") { project in
            project.timeline = TimelineSettings(trimStart: 0, trimEnd: duration)
        }
    }

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
        player.isMuted = project.resolvedIsAudioMuted
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
            selectedZoomID = nil
            selectedReframeID = nil
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
            selectedZoomID = nil
            selectedReframeID = nil
        }
    }

    func updateCustomZoomBehavior(
        _ keyPath: WritableKeyPath<ZoomBehaviorSettings, Double>,
        value: Double,
        actionName: String
    ) {
        guard value.isFinite, zoomBehavior.preset != .off else { return }
        editProject(actionName: actionName, rebuildPreview: false) { project in
            var settings = project.resolvedZoomBehavior
            settings.preset = .custom
            settings[keyPath: keyPath] = value
            project.zoomBehavior = settings
        }
    }

    func setZoomMotionStyle(_ style: ZoomBehaviorSettings.MotionStyle) {
        editProject(actionName: "Change Camera Motion") { project in
            var settings = project.resolvedZoomBehavior
            settings.motionStyle = style
            project.zoomBehavior = settings
        }
    }

    func addManualZoom() {
        let time = min(trimEnd, max(trimStart, playheadTime))
        let settings = zoomBehavior
        let lead = min(0.25, settings.transitionDuration * 0.4)
        let start = max(trimStart, time - lead)
        let end = min(trimEnd, time + settings.holdDuration + settings.transitionDuration)
        guard end - start >= 0.1 else { return }
        var segment = ZoomSegment(
            id: UUID(),
            startTime: start,
            focusTime: time + settings.transitionDuration,
            endTime: end,
            focusPoint: CodablePoint(CGPoint(x: Double(project.recording.width) / 2,
                                            y: Double(project.recording.height) / 2)),
            scale: settings.scale,
            source: .manual,
            transitionDuration: settings.transitionDuration,
            entranceDuration: time - start + settings.transitionDuration
        )
        segment.normalizeTiming()
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
        if selectedZoomID == id {
            selectedZoomID = nil
            selectedReframeID = nil
        }
    }

    func selectZoom(id: UUID, seekToFocus: Bool = true) {
        if selectedZoomID != id {
            selectedReframeID = nil
        }
        selectedZoomID = id
        guard
            seekToFocus,
            let zoom = project.zoomSegments.first(where: { $0.id == id })
        else { return }
        seek(to: zoom.focusTime)
    }

    func selectBaseViewbox(for zoomID: UUID, seek: Bool = true) {
        selectZoom(id: zoomID, seekToFocus: false)
        selectedReframeID = nil
        if seek, let zoom = selectedZoom {
            self.seek(to: zoom.focusTime)
        }
    }

    func selectReframe(id: UUID, in zoomID: UUID, seek: Bool = true) {
        selectZoom(id: zoomID, seekToFocus: false)
        guard let reframe = selectedZoom?.reframes.first(where: { $0.id == id }) else {
            selectedReframeID = nil
            return
        }
        selectedReframeID = id
        if seek {
            self.seek(to: reframe.time)
        }
    }

    func selectCameraPosition(_ position: ZoomCameraPosition, in zoomID: UUID, seek: Bool = true) {
        if position.isInitial {
            selectBaseViewbox(for: zoomID, seek: seek)
        } else {
            selectReframe(id: position.id, in: zoomID, seek: seek)
        }
    }

    func canAddReframe(to zoomID: UUID) -> Bool {
        guard let zoom = project.zoomSegments.first(where: { $0.id == zoomID }) else {
            return false
        }
        return playheadTime > zoom.focusTime + 1.0 / 30.0
            && playheadTime <= zoom.endTime - 0.1
    }

    func canAddCameraPosition(to zoomID: UUID) -> Bool {
        canAddReframe(to: zoomID)
    }

    @discardableResult
    func addReframeAtPlayhead(to zoomID: UUID) -> UUID? {
        guard
            let index = project.zoomSegments.firstIndex(where: { $0.id == zoomID }),
            canAddReframe(to: zoomID)
        else { return nil }

        let zoom = project.zoomSegments[index]
        let time = min(zoom.endTime - 0.1, max(zoom.focusTime, playheadTime))
        if let existing = zoom.reframes.first(where: { abs($0.time - time) < 1.0 / 30.0 }) {
            selectReframe(id: existing.id, in: zoomID)
            return existing.id
        }

        let preceding = zoom.reframes
            .filter { $0.time <= time }
            .max { $0.time < $1.time }
        let reframe = ZoomReframe(
            time: time,
            focusPoint: preceding?.focusPoint ?? zoom.focusPoint,
            scale: preceding?.scale ?? zoom.scale
        )
        editProject(actionName: "Add Camera Position") { project in
            project.zoomSegments[index].reframes.append(reframe)
            project.zoomSegments[index].reframes.sort { $0.time < $1.time }
            project.zoomSegments[index].source = .manual
        }
        selectedZoomID = zoomID
        selectedReframeID = reframe.id
        seek(to: reframe.time)
        return reframe.id
    }

    @discardableResult
    func addCameraPositionAtPlayhead(to zoomID: UUID) -> UUID? {
        addReframeAtPlayhead(to: zoomID)
    }

    func deleteReframe(id: UUID, from zoomID: UUID) {
        guard let index = project.zoomSegments.firstIndex(where: { $0.id == zoomID }) else {
            return
        }
        editProject(actionName: "Delete Camera Position") { project in
            project.zoomSegments[index].reframes.removeAll { $0.id == id }
        }
        if selectedReframeID == id {
            selectedReframeID = nil
        }
    }


    func deleteCameraPosition(id: UUID, from zoomID: UUID) {
        guard let zoom = project.zoomSegments.first(where: { $0.id == zoomID }) else {
            return
        }
        let positions = cameraPositions(for: zoom)
        guard let deletedIndex = positions.firstIndex(where: { $0.id == id }) else {
            return
        }
        let fallback = positions[max(0, deletedIndex - 1)]
        deleteReframe(id: id, from: zoomID)
        selectCameraPosition(fallback, in: zoomID)
    }

    func togglePlayback() {
        if player.rate != 0 {
            player.pause()
        } else {
            let frameDuration = 1.0 / Double(max(1, project.recording.framesPerSecond))
            if playheadTime >= trimEnd - frameDuration / 2 || playheadTime < trimStart {
                seek(to: trimStart)
            }
            player.play()
        }
    }

    func jumpToStart() {
        seek(to: trimStart)
    }

    func stepFrame(by direction: Int) {
        player.pause()
        let frameDuration = 1.0 / Double(max(1, project.recording.framesPerSecond))
        seek(to: playheadTime + Double(direction) * frameDuration)
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
        let timeDelta = start - project.zoomSegments[index].startTime
        project.zoomSegments[index].startTime = start
        project.zoomSegments[index].focusTime = min(start + duration, start + focusOffset)
        project.zoomSegments[index].endTime = start + duration
        for reframeIndex in project.zoomSegments[index].reframes.indices {
            project.zoomSegments[index].reframes[reframeIndex].time += timeDelta
        }
    }

    func resizeZoomStart(id: UUID, to proposedStart: Double) {
        guard let index = project.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        project.zoomSegments[index].normalizeTiming()
        let latest = project.zoomSegments[index].endTime - 0.1
        let start = min(max(0, proposedStart), latest)
        project.zoomSegments[index].startTime = start
        project.zoomSegments[index].normalizeTiming()
        let earliestReframe = project.zoomSegments[index].focusTime
        for reframeIndex in project.zoomSegments[index].reframes.indices {
            project.zoomSegments[index].reframes[reframeIndex].time = max(
                earliestReframe,
                project.zoomSegments[index].reframes[reframeIndex].time
            )
        }
    }

    func resizeZoomEnd(id: UUID, to proposedEnd: Double) {
        guard let index = project.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        project.zoomSegments[index].normalizeTiming()
        let earliest = project.zoomSegments[index].startTime + 0.1
        let end = max(earliest, min(recordingDuration, proposedEnd))
        project.zoomSegments[index].endTime = end
        project.zoomSegments[index].normalizeTiming()
        let latestReframe = max(project.zoomSegments[index].focusTime,
                               project.zoomSegments[index].timing.exitStart - 0.1)
        for reframeIndex in project.zoomSegments[index].reframes.indices {
            project.zoomSegments[index].reframes[reframeIndex].time = min(
                latestReframe,
                project.zoomSegments[index].reframes[reframeIndex].time
            )
        }
        project.zoomSegments[index].reframes.sort { $0.time < $1.time }
    }

    func commitTimelineEdit() {
        project.zoomSegments.sort { $0.startTime < $1.startTime }
        project.synchronizeCameraEffects()
        projectDidChange()
        commitHistoryTransaction()
    }

    func setSelectedZoomFocus(_ point: CGPoint) {
        guard let selectedZoom else { return }
        setSelectedZoomViewbox(focusPoint: point, scale: selectedZoom.scale)
    }

    func setSelectedZoomViewbox(focusPoint: CGPoint, scale: Double) {
        guard
            let selectedZoomID,
            let index = project.zoomSegments.firstIndex(where: { $0.id == selectedZoomID })
        else { return }

        let clampedScale = min(3.5, max(1.1, scale))
        let halfWidth = Double(project.recording.width) / (2 * clampedScale)
        let halfHeight = Double(project.recording.height) / (2 * clampedScale)
        editProject(
            actionName: "Change Zoom Viewbox",
            rebuildPreview: !isEditingViewbox
        ) { project in
            let clampedFocus = CodablePoint(CGPoint(
                x: min(Double(project.recording.width) - halfWidth, max(halfWidth, focusPoint.x)),
                y: min(Double(project.recording.height) - halfHeight, max(halfHeight, focusPoint.y))
            ))
            if
                let selectedReframeID,
                let reframeIndex = project.zoomSegments[index].reframes.firstIndex(
                    where: { $0.id == selectedReframeID }
                )
            {
                project.zoomSegments[index].reframes[reframeIndex].focusPoint = clampedFocus
                project.zoomSegments[index].reframes[reframeIndex].scale = clampedScale
            } else {
                project.zoomSegments[index].focusPoint = clampedFocus
                project.zoomSegments[index].scale = clampedScale
            }
            project.zoomSegments[index].source = .manual
        }
    }

    func setViewboxEditing(_ isEditing: Bool) {
        guard isEditingViewbox != isEditing else { return }
        isEditingViewbox = isEditing
        player.pause()
        rebuildPreview(preservingTime: true)
    }

    func setAudioMuted(_ muted: Bool) {
        editProject(actionName: muted ? "Mute Audio" : "Unmute Audio", rebuildPreview: false) {
            $0.isAudioMuted = muted
        }
    }

    func applyBackground(_ preset: BackgroundPreset) {
        BackgroundPreferences().remember(preset)
        editProject(actionName: "Change Background") { project in
            project.canvas.backgroundImage = nil
            project.canvas.backgroundStartHex = preset.startHex
            project.canvas.backgroundEndHex = preset.endHex
        }
    }

    var backgroundImageURL: URL? {
        BackgroundImages.url(for: project.canvas.backgroundImage, in: projectURL)
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a background image"
        panel.prompt = "Use Image"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyBackgroundImage(at: url)
    }

    func applyBackgroundImage(at url: URL, name: String? = nil) {
        do {
            let asset = try BackgroundImages.importImage(at: url, into: projectURL, name: name)
            editProject(actionName: "Change Background") { $0.canvas.backgroundImage = asset }
            if let savedURL = BackgroundImages.url(for: asset, in: projectURL) {
                try BackgroundPreferences().rememberImage(at: savedURL, name: asset.name)
            }
        } catch { present(error) }
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
            project.synchronizeCameraEffects()
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

    var exportDimensionsLabel: String {
        let size = CanvasGeometry(project: project, quality: quality).canvasSize
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    func exportVideo() async {
        let panel = NSSavePanel()
        panel.title = "Export Showcase Video"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = projectURL.deletingPathExtension().lastPathComponent
            + "-" + project.canvas.aspectRatio.filenameSuffix + "-" + quality.displayName + ".mp4"

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
        previewRefreshTask?.cancel()
        previewRefreshTask = nil
        let currentTime = preservingTime ? player.currentTime() : .zero
        let wasPlaying = player.rate != 0
        let locations = projectStore.locations(for: projectURL)
        let asset = AVURLAsset(url: locations.videoURL)
        var previewProject = project
        if isEditingViewbox {
            previewProject.zoomSegments = []
            if previewProject.cameraOverlay != nil {
                previewProject.cameraOverlay?.isVisible = false
            }
            previewProject.motionBlur = .disabled
        }
        let built = VideoCompositionBuilder().build(
            asset: asset,
            project: previewProject,
            events: events,
            quality: quality,
            purpose: .preview,
            cameraVideoURL: !isEditingViewbox && project.recording.cameraVideoRelativePath != nil
                ? locations.cameraVideoURL
                : nil,
            projectURL: projectURL
        )
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = built.composition
        item.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        player.isMuted = project.resolvedIsAudioMuted
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
            self.selectedZoomID = nil
            selectedReframeID = nil
        }
        if let selectedReframeID, selectedReframe?.id != selectedReframeID {
            self.selectedReframeID = nil
        }
        if let selectedCameraID, !project.resolvedCameraSegments.contains(where: { $0.id == selectedCameraID }) {
            self.selectedCameraID = nil
        }
        if let selectedCameraEmphasisID, !project.cameraTimelineEmphases.contains(where: { $0.id == selectedCameraEmphasisID }) {
            self.selectedCameraEmphasisID = nil
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

struct ZoomViewboxEditTarget: Equatable, Identifiable {
    let id: UUID
    let focusPoint: CGPoint
    let scale: Double
    let time: Double
    let cursorBoundaryFraction: Double
}

struct ZoomCameraPosition: Equatable, Identifiable {
    let id: UUID
    let time: Double
    let focusPoint: CGPoint
    let scale: Double
    let isInitial: Bool
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
