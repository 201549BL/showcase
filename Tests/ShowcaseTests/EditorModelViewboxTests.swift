import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import Showcase

@Suite("Editor viewbox interaction")
struct EditorModelViewboxTests {
    @Test("Deleting a timeline selection saves the change and supports undo and redo")
    @MainActor
    func deleteTimelineSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root, withCamera: true)
        let zoom = try #require(model.selectedZoom)
        #expect(model.deleteSelectedTimelineEffect())
        #expect(!model.project.zoomSegments.contains { $0.id == zoom.id })
        #expect(model.selectedZoomID == nil)
        #expect(try !ProjectStore().loadProject(at: model.projectURL).zoomSegments.contains { $0.id == zoom.id })
        #expect(!model.deleteSelectedTimelineEffect())
        model.undo()
        #expect(model.project.zoomSegments.contains { $0.id == zoom.id })
        model.redo()
        #expect(!model.project.zoomSegments.contains { $0.id == zoom.id })

        model.seek(to: 0)
        model.addCameraEmphasis()
        let effect = try #require(model.selectedCameraEmphasis)
        #expect(model.deleteSelectedTimelineEffect())
        #expect(!model.project.cameraTimelineEmphases.contains { $0.id == effect.id })
        model.undo()
        #expect(model.project.cameraTimelineEmphases.contains { $0.id == effect.id })

        model.selectedCameraID = try #require(model.project.resolvedCameraSegments.first).id
        #expect(model.deleteSelectedTimelineEffect())
        #expect(model.project.resolvedCameraSegments.isEmpty)
        model.undo()
        #expect(!model.project.resolvedCameraSegments.isEmpty)
    }

    @Test("Image backgrounds save, undo, redo, and switch back to gradients")
    @MainActor
    func backgroundImageHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root)
        let imageURL = root.appendingPathComponent("Background.png")
        try writeBackgroundFixture(to: imageURL)
        model.applyBackgroundImage(at: imageURL)
        let image = try #require(model.project.canvas.backgroundImage)
        #expect(model.presentedError == nil)
        model.undo()
        #expect(model.project.canvas.backgroundImage == nil)
        model.redo()
        #expect(model.project.canvas.backgroundImage == image)
        model.applyBackground(.ocean)
        #expect(model.project.canvas.backgroundImage == nil)
        model.undo()
        #expect(model.project.canvas.backgroundImage == image)
        let reopened = try EditorModel(projectURL: model.projectURL)
        #expect(reopened.project.canvas.backgroundImage == image)
        #expect(reopened.backgroundImageURL.flatMap { BackgroundImages.image(at: $0) } != nil)
    }

    @Test("Dragging the viewbox does not replace the player item while editing")
    @MainActor
    func viewboxEditKeepsPlayerStable() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let model = try await makeFixture(in: temporaryRoot)
        let zoomID = try #require(model.selectedZoomID)
        let audioPlayerItem = model.player.currentItem
        model.setAudioMuted(true)
        #expect(model.player.isMuted)
        #expect(model.player.currentItem === audioPlayerItem)
        #expect(try ProjectStore().loadProject(at: model.projectURL).resolvedIsAudioMuted)
        model.undo()
        #expect(!model.player.isMuted)
        model.redo()
        #expect(model.player.isMuted)
        model.setAudioMuted(false)
        #expect(!model.player.isMuted)
        let initialZoom = try #require(model.selectedZoom)
        let initialPositions = model.cameraPositions(for: initialZoom)
        #expect(initialPositions.map(\.id) == [zoomID])
        #expect(initialPositions.first?.isInitial == true)

        model.setViewboxEditing(true)
        let playerItem = try #require(model.player.currentItem)

        model.setSelectedZoomViewbox(
            focusPoint: CGPoint(x: 180, y: 100),
            scale: 1.7
        )
        try await Task.sleep(for: .milliseconds(300))

        #expect(model.selectedZoom?.focusPoint.cgPoint == CGPoint(x: 180, y: 100))
        #expect(model.selectedZoom?.scale == 1.7)
        #expect(model.player.currentItem === playerItem)

        model.seek(to: 0.7)
        let reframeID = try #require(model.addReframeAtPlayhead(to: zoomID))
        model.setSelectedZoomViewbox(
            focusPoint: CGPoint(x: 200, y: 110),
            scale: 1.8
        )

        let reframe = try #require(
            model.selectedZoom?.reframes.first(where: { $0.id == reframeID })
        )
        let positions = model.cameraPositions(for: try #require(model.selectedZoom))
        #expect(positions.map(\.id) == [zoomID, reframeID])
        #expect(positions.map(\.isInitial) == [true, false])
        #expect(reframe.focusPoint.cgPoint == CGPoint(x: 200, y: 110))
        #expect(reframe.scale == 1.8)
        #expect(model.selectedZoom?.focusPoint.cgPoint == CGPoint(x: 180, y: 100))
    }

    @Test("Global settings stay visible through preset changes and undo")
    @MainActor
    func globalSettingsPreserveNoSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root)
        let zoomID = try #require(model.selectedZoomID)
        model.selectedZoomID = nil

        model.applyZoomPreset(.off)
        let disabledSettings = model.zoomBehavior
        model.updateCustomZoomBehavior(\.scale, value: 2.2, actionName: "Change Zoom Magnification")
        #expect(model.zoomBehavior == disabledSettings)
        #expect(model.selectedZoomID == nil)
        model.undo()
        #expect(model.selectedZoomID == nil)
        model.redo()
        #expect(model.selectedZoomID == nil)
        model.regenerateAutomaticZooms()
        #expect(model.selectedZoomID == nil)

        model.selectZoom(id: zoomID, seekToFocus: false)
        model.applyZoomPreset(.calm)
        #expect(model.selectedZoomID == zoomID)
        model.undo()
        #expect(model.selectedZoomID == zoomID)
        model.deleteZoom(id: zoomID)
        #expect(model.selectedZoomID == nil)
        model.undo()
        #expect(model.project.zoomSegments.contains { $0.id == zoomID })
        #expect(model.selectedZoomID == nil)
    }

    @Test("Playback transport steps frames and respects trimmed boundaries")
    @MainActor
    func playbackTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root)
        model.setTrimStart(0.2)
        model.setTrimEnd(0.8)
        model.seek(to: 0.5)
        model.stepFrame(by: 1)
        #expect(abs(model.playheadTime - (0.5 + 1.0 / 30)) < 0.0001)
        model.stepFrame(by: -1)
        #expect(abs(model.playheadTime - 0.5) < 0.0001)

        model.jumpToStart()
        #expect(model.playheadTime == 0.2)
        model.stepFrame(by: -1)
        #expect(model.playheadTime == 0.2)
        model.seek(to: 0.8)
        model.stepFrame(by: 1)
        #expect(model.playheadTime == 0.8)

        model.togglePlayback()
        #expect(model.playheadTime == 0.2)
        #expect(model.player.rate != 0)
        model.stepFrame(by: 1)
        #expect(model.player.rate == 0)
        #expect(abs(model.playheadTime - (0.2 + 1.0 / 30)) < 0.0001)
    }

    @Test("Resizing preserves entrance timing through short clips and undo")
    @MainActor
    func resizePreservesZoomTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root, duration: 12)
        let id = try #require(model.selectedZoomID)
        model.editProject(actionName: "Extend fixture") { $0.zoomSegments[0].endTime = 4 }

        model.beginHistoryTransaction(actionName: "Resize Zoom")
        model.resizeZoomStart(id: id, to: 1)
        model.commitTimelineEdit()
        #expect(model.selectedZoom?.focusTime == 1.5)
        model.undo()
        #expect(model.selectedZoom?.focusTime == 0.5)
        #expect(model.selectedZoom?.startTime == 0)

        model.beginHistoryTransaction(actionName: "Resize Zoom")
        model.resizeZoomEnd(id: id, to: 0.2)
        #expect(abs(try #require(model.selectedZoom).timing.entranceDuration - 0.1) < 0.0001)
        model.resizeZoomEnd(id: id, to: 4)
        model.commitTimelineEdit()
        #expect(model.selectedZoom?.focusTime == 0.5)
        #expect(model.selectedZoom?.timing.exitDuration == 0.5)
    }

    @Test("New manual zooms use current motion settings and stay inside the trim")
    @MainActor
    func manualZoomUsesMotionSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root, duration: 12)
        model.applyZoomPreset(.focused)
        model.seek(to: 5)
        model.addManualZoom()
        let zoom = try #require(model.selectedZoom)
        #expect(zoom.scale == model.zoomBehavior.scale)
        #expect(zoom.transitionDuration == model.zoomBehavior.transitionDuration)
        #expect(abs(zoom.focusTime - 5.35) < 0.0001)
        #expect(abs(zoom.endTime - 6.1) < 0.0001)

        model.setTrimStart(2)
        model.setTrimEnd(8)
        model.seek(to: 8)
        model.addManualZoom()
        let last = try #require(model.selectedZoom)
        #expect(last.startTime >= 2)
        #expect(last.endTime == 8)
        #expect(last.timing.focusTime < last.endTime)
        #expect(last.timing.exitDuration > 0)
    }

    @Test("Trim handle edits clamp, undo as one gesture, and preserve zooms")
    @MainActor
    func trimHandleHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root, duration: 12)
        let zooms = model.project.zoomSegments
        model.beginHistoryTransaction(actionName: "Trim Start")
        model.setTrimStart(0.5)
        model.setTrimStart(1)
        model.setTrimStart(2)
        model.commitHistoryTransaction()
        #expect(model.trimStart == 2)
        #expect(model.isTrimmed)
        model.undo()
        #expect(model.trimStart == 0)
        #expect(!model.isTrimmed)
        model.redo()
        #expect(model.trimStart == 2)

        model.setTrimEnd(1)
        #expect(abs(model.trimEnd - 2.1) < 0.0001)
        model.setTrimStart(10)
        #expect(model.trimStart <= model.trimEnd - 0.1)
        model.resetTrim()
        #expect(model.trimStart == 0)
        #expect(model.trimEnd == 12)
        #expect(!model.isTrimmed)
        model.undo()
        #expect(abs(model.trimEnd - 2.1) < 0.0001)
        #expect(model.project.zoomSegments == zooms)
    }

    @Test("Camera sections split, resize, move, and undo without changing zooms or camera defaults")
    @MainActor
    func cameraSectionEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root, duration: 12, withCamera: true)
        let zooms = model.project.zoomSegments
        let defaults = model.project.resolvedCameraOverlay
        #expect(model.project.cameraSegments == nil)
        let original = try #require(model.project.resolvedCameraSegments.first)
        #expect(original.startTime == 0 && original.endTime == 12)
        #expect(!model.canAddCamera)
        model.seek(to: 5)
        model.selectCamera(id: original.id)
        #expect(model.selectedZoomID == nil)
        #expect(model.canSplitCamera)
        model.splitCameraSection()
        let right = try #require(model.selectedCamera)
        #expect(right.startTime == 5 && right.endTime == 12)
        #expect(model.project.resolvedCameraSegments.count == 2)
        model.editCameraSettings(actionName: "Move Face Camera") { $0.corner = .topLeft }
        #expect(model.project.cameraSettings(at: 6)?.corner == .topLeft)
        #expect(model.project.cameraSettings(at: 4)?.corner == defaults.corner)
        #expect(model.project.resolvedCameraOverlay == defaults)
        model.undo()
        #expect(model.project.cameraSettings(at: 6)?.corner == defaults.corner)
        model.undo()
        #expect(model.project.cameraSegments == nil)
        #expect(model.selectedCameraID == nil)
        model.redo()
        model.selectCamera(id: right.id)
        model.beginHistoryTransaction(actionName: "Resize Camera Section")
        model.updateCameraTiming(id: right.id, to: 7, edge: .start)
        model.updateCameraTiming(id: right.id, to: 8, edge: .start)
        model.updateCameraTiming(id: right.id, to: 10, edge: .end)
        model.commitTimelineEdit()
        #expect(model.selectedCamera?.startTime == 8)
        #expect(model.selectedCamera?.endTime == 10)
        model.undo()
        #expect(model.selectedCamera?.startTime == 5)
        #expect(model.selectedCamera?.endTime == 12)
        model.redo()
        model.beginHistoryTransaction(actionName: "Move Camera Section")
        model.updateCameraTiming(id: right.id, to: -10, edge: .move)
        model.commitTimelineEdit()
        #expect(model.selectedCamera?.startTime == 5)
        #expect(model.selectedCamera?.endTime == 7)
        model.beginHistoryTransaction(actionName: "Resize Camera Section")
        model.updateCameraTiming(id: right.id, to: 0, edge: .start)
        model.updateCameraTiming(id: right.id, to: 99, edge: .end)
        model.commitTimelineEdit()
        #expect(model.selectedCamera?.startTime == 5)
        #expect(model.selectedCamera?.endTime == 12)
        model.deleteCameraSection(id: right.id)
        model.seek(to: 6)
        #expect(model.canAddCamera)
        model.addCameraSection()
        #expect(model.selectedCamera?.startTime == 6)
        #expect(model.selectedCamera?.endTime == 9)
        #expect(model.project.cameraSettings(at: 5.5) == nil)
        #expect(model.project.zoomSegments == zooms)
        model.selectZoom(id: zooms[0].id, seekToFocus: false)
        #expect(model.selectedCameraID == nil)
        for section in model.project.resolvedCameraSegments { model.deleteCameraSection(id: section.id) }
        #expect(model.project.cameraSegments == [])
        #expect(model.project.cameraSettings(at: 1) == nil)
        let saved = try ProjectStore().loadProject(at: model.projectURL)
        #expect(saved.cameraSegments == [])
        model.undo()
        #expect(model.project.resolvedCameraSegments.count == 1)
    }

    @Test("Camera emphasis edits are independent of visibility, settings, and screen zooms")
    @MainActor
    func cameraEmphasisEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root, duration: 12, withCamera: true)
        model.project.cameraOverlay = .default
        model.project.cameraOverlay?.sizingMode = .fixed
        model.project.synchronizeCameraEffects()
        let originalProject = model.project
        #expect(!model.showsCameraEmphasisTrack)
        #expect(model.canAddCameraEmphasis)
        model.seek(to: 2)
        model.addCameraEmphasis()
        let effect = try #require(model.selectedCameraEmphasis)
        #expect(effect.startTime == 2 && effect.endTime == 4.5)
        #expect(model.showsCameraEmphasisTrack)
        #expect(model.selectedZoomID == nil && model.selectedCameraID == nil)
        #expect(!model.canAddCameraEmphasis)
        model.addCameraEmphasis()
        #expect(model.project.resolvedCameraEmphases.count == 1)
        model.beginHistoryTransaction(actionName: "Resize Camera Emphasis")
        model.updateCameraEmphasisTiming(id: effect.id, to: 2.2, edge: .end)
        model.updateCameraEmphasisTiming(id: effect.id, to: 2.1, edge: .end)
        model.commitTimelineEdit()
        #expect(model.selectedCameraEmphasis?.endTime == 2.1)
        model.undo()
        #expect(model.selectedCameraEmphasis?.endTime == 4.5)
        model.beginHistoryTransaction(actionName: "Move Camera Emphasis")
        model.updateCameraEmphasisTiming(id: effect.id, to: -2, edge: .move)
        model.commitTimelineEdit()
        #expect(model.selectedCameraEmphasis?.startTime == 0)
        model.editCameraEmphasis(id: effect.id, actionName: "Change Size") { $0.targetSize = 0.5 }
        #expect(model.project.emphasizedCameraSize(0.22, at: 1) == 0.5)
        let loaded = try ProjectStore().loadProject(at: model.projectURL)
        #expect(loaded.cameraEmphases == model.project.cameraEmphases)
        #expect(model.project.cameraSegments == originalProject.cameraSegments)
        #expect(model.project.cameraOverlay == originalProject.cameraOverlay)
        #expect(model.project.zoomSegments == originalProject.zoomSegments)
        model.seek(to: 10)
        model.addCameraEmphasis()
        let second = try #require(model.selectedCameraEmphasis)
        model.beginHistoryTransaction(actionName: "Move Camera Emphasis")
        model.updateCameraEmphasisTiming(id: second.id, to: 0, edge: .move)
        model.commitTimelineEdit()
        #expect(model.selectedCameraEmphasis?.startTime == 2.5)
        model.undo()
        model.selectCamera(id: model.project.resolvedCameraSegments[0].id)
        #expect(model.selectedCameraEmphasisID == nil)
        model.selectCameraEmphasis(id: effect.id)
        #expect(model.selectedCameraID == nil)
        model.deleteCameraEmphasis(id: effect.id)
        #expect(model.selectedCameraEmphasisID == nil)
        model.deleteCameraEmphasis(id: second.id)
        #expect(!model.showsCameraEmphasisTrack)
        model.undo()
        #expect(model.showsCameraEmphasisTrack)
        model.editProject(actionName: "Hide camera") { $0.cameraSegments = [] }
        model.seek(to: 6)
        #expect(!model.canAddCameraEmphasis)
    }

    @Test("Global camera appearance edits update the same property on older clip overrides")
    @MainActor
    func cameraAppearanceUpdatesLegacyClips() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root, withCamera: true)
        var oldSettings = CameraOverlaySettings.default
        oldSettings.corner = .topLeft
        oldSettings.isMirrored = false
        model.project.cameraSegments = [CameraSegment(startTime: 0, endTime: 1, settings: oldSettings)]
        var consolidated = model.project
        let appearance = consolidated.cameraSettings(at: 0.5)
        consolidated.consolidateCameraAppearance()
        #expect(consolidated.cameraSettings(at: 0.5) == appearance)
        #expect(consolidated.resolvedCameraOverlay == oldSettings)
        #expect(consolidated.cameraSegments?.first?.settings == nil)
        consolidated.cameraOverlay?.isVisible = false
        consolidated.cameraSegments?[0].settings = oldSettings
        consolidated.consolidateCameraAppearance()
        #expect(!consolidated.resolvedCameraOverlay.isVisible)
        #expect(consolidated.cameraSettings(at: 0.5) == nil)
        var different = model.project
        different.cameraSegments?.append(CameraSegment(startTime: 1, endTime: 2, settings: .default))
        let unchanged = different
        different.consolidateCameraAppearance()
        #expect(different == unchanged)
        let before = model.project
        model.editCameraSettings(actionName: "Camera size", updateClipOverrides: true) { $0.size = 0.3 }
        #expect(model.project.resolvedCameraOverlay.size == 0.3)
        #expect(model.project.cameraSettings(at: 0.5)?.size == 0.3)
        #expect(model.project.cameraSettings(at: 0.5)?.corner == .topLeft)
        #expect(model.project.cameraSettings(at: 0.5)?.isMirrored == false)
        model.undo()
        #expect(model.project == before)
    }

    @Test("Generated camera sizes are persisted, editable effects with ordinary timing, deletion, and undo")
    @MainActor
    func automaticCameraEffects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root, duration: 12, withCamera: true)
        let zoomID = model.project.zoomSegments[0].id
        #expect(model.project.cameraEmphases?.count == 1)
        #expect(model.showsCameraEmphasisTrack)
        #expect(model.project.resolvedCameraEmphases[0].id == zoomID)
        model.beginHistoryTransaction(actionName: "Resize Zoom")
        model.resizeZoomEnd(id: zoomID, to: 4)
        model.commitTimelineEdit()
        #expect(model.project.resolvedCameraEmphases[0].endTime == 4)
        model.seek(to: 1)
        #expect(!model.canAddCameraEmphasis)
        model.selectCameraEmphasis(id: zoomID)
        model.editCameraEmphasis(id: zoomID, actionName: "Change Size") { $0.targetSize = 0.16 }
        #expect(model.selectedCameraEmphasis?.targetSize == 0.16)
        #expect(model.project.emphasizedCameraSize(0.28, at: 2) == 0.16)
        model.beginHistoryTransaction(actionName: "Resize Camera Effect")
        model.updateCameraEmphasisTiming(id: zoomID, to: 2, edge: .end)
        model.commitTimelineEdit()
        #expect(model.selectedCameraEmphasis?.endTime == 2)
        model.seek(to: 3)
        #expect(model.canAddCameraEmphasis)
        model.addCameraEmphasis()
        let manual = try #require(model.selectedCameraEmphasis)
        #expect(model.project.resolvedCameraEmphases.count == 2)
        model.deleteCameraEmphasis(id: zoomID)
        #expect(model.project.resolvedCameraEmphases == [manual])
        let decoded = try ProjectStore().loadProject(at: model.projectURL)
        #expect(decoded.cameraEmphases == [manual])
        let reopened = try EditorModel(projectURL: model.projectURL)
        #expect(reopened.project.cameraEmphases == [manual])
        model.undo()
        #expect(model.project.resolvedCameraEmphases.count == 2)
        model.undo()
        model.undo()
        #expect(model.project.resolvedCameraEmphases[0].endTime == 4)
        model.undo()
        #expect(model.project.resolvedCameraEmphases[0].isAutomatic)
        model.deleteCameraEmphasis(id: zoomID)
        #expect(model.project.resolvedCameraEmphases.isEmpty)
        let beforeRecommended = model.project
        model.useRecommendedCameraBehavior()
        #expect(model.project.resolvedCameraEmphases.count == 1)
        model.undo()
        #expect(model.project == beforeRecommended)
    }

    @Test("Legacy manual effects keep their ranges while zoom size effects fill the remaining gaps")
    @MainActor
    func generatedCameraEffectsPreserveManualRanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeFixture(in: root, duration: 12, withCamera: true)
        model.project.zoomSegments[0].endTime = 8
        let manual = CameraEmphasis(startTime: 3, endTime: 5, targetSize: 0.45)
        model.project.cameraEmphases = [manual]
        model.project.synchronizeCameraEffects()
        let effects = model.project.resolvedCameraEmphases
        #expect(effects.count == 3)
        #expect(effects[0].startTime == 0 && effects[0].endTime == 3)
        #expect(effects[1] == manual)
        #expect(effects[2].startTime == 5 && effects[2].endTime == 8)
        model.project.synchronizeCameraEffects()
        #expect(model.project.resolvedCameraEmphases == effects)
        model.editCameraEmphasis(id: effects[0].id, actionName: "Change Size") { $0.targetSize = 0.18 }
        #expect(model.project.resolvedCameraEmphases[0].targetSize == 0.18)
        #expect(model.project.resolvedCameraEmphases[1] == manual)
        #expect(model.project.resolvedCameraEmphases[2].id == effects[2].id)
        model.deleteCameraEmphasis(id: effects[0].id)
        #expect(model.project.resolvedCameraEmphases.count == 2)
        #expect(model.project.resolvedCameraEmphases.last?.id == effects[2].id)
    }

    @MainActor
    private func makeFixture(in temporaryRoot: URL, duration: Double = 1, withCamera: Bool = false) async throws -> EditorModel {
        let store = ProjectStore(projectsDirectory: temporaryRoot)
        let locations = try store.createProjectDirectory(named: "Viewbox Fixture")
        try await createFixtureVideo(at: locations.videoURL, duration: duration)

        let zoomID = UUID()
        var project = RecordingProject(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            recording: RecordingMetadata(
                source: CaptureSourceDescriptor(
                    kind: .display,
                    sourceID: 1,
                    title: "Fixture",
                    applicationName: nil,
                    frame: CodableRect(CGRect(x: 0, y: 0, width: 320, height: 180)),
                    scaleFactor: 1
                ),
                width: 320,
                height: 180,
                framesPerSecond: 30,
                duration: duration,
                includesSystemAudio: false,
                includesMicrophone: false,
                videoRelativePath: "media/screen.mov",
                eventsRelativePath: "events/input-events.json"
            )
        )
        project.zoomSegments = [
            ZoomSegment(
                id: zoomID,
                startTime: 0,
                focusTime: 0.5,
                endTime: 1,
                focusPoint: CodablePoint(CGPoint(x: 160, y: 90)),
                scale: 1.5,
                source: .manual
            )
        ]
        if withCamera {
            project.recording.cameraVideoRelativePath = "media/camera.mov"
            try FileManager.default.copyItem(at: locations.videoURL, to: locations.projectURL.appendingPathComponent("media/camera.mov"))
        }
        try store.save(project, to: locations)
        try store.save(events: [], to: locations)

        return try EditorModel(projectURL: locations.projectURL, projectStore: store)
    }

    private func createFixtureVideo(at url: URL, duration: Double) async throws {
        let width = 320
        let height = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { throw FixtureError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.cannotStartWriting }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw FixtureError.noPixelBufferPool }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { throw FixtureError.noPixelBuffer }
        let image = CIImage(
            color: CIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        CIContext().render(image, to: pixelBuffer)

        for frame in [0, Int(duration * 30) - 1] {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: Int64(frame), timescale: 30)
            ) else {
                throw writer.error ?? FixtureError.cannotAppendFrame
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? FixtureError.cannotFinishWriting
        }
    }
}

private enum FixtureError: Error {
    case cannotAddInput
    case cannotStartWriting
    case noPixelBufferPool
    case noPixelBuffer
    case cannotAppendFrame
    case cannotFinishWriting
}
