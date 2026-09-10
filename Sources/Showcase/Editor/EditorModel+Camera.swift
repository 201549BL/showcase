import Foundation

extension EditorModel {
    var selectedCamera: CameraSegment? {
        project.resolvedCameraSegments.first { $0.id == selectedCameraID }
    }

    var cameraInspectorSettings: CameraOverlaySettings {
        selectedCamera?.settings ?? project.resolvedCameraOverlay
    }

    var canAddCamera: Bool {
        project.hasCamera && cameraGapEnd - playheadTime >= 0.1
            && playheadTime >= trimStart && project.cameraSegment(at: playheadTime) == nil
    }

    private var cameraGapEnd: Double {
        min(trimEnd, project.resolvedCameraSegments.filter { $0.startTime > playheadTime }
            .map(\.startTime).min() ?? trimEnd)
    }

    var canSplitCamera: Bool {
        guard let section = selectedCamera ?? project.cameraSegment(at: playheadTime) else { return false }
        return playheadTime - section.startTime >= 0.1 && section.endTime - playheadTime >= 0.1
    }

    func selectCamera(id: UUID, seekToStart: Bool = true) {
        selectedCameraID = id
        if seekToStart, let section = selectedCamera {
            player.pause()
            // Keep a playhead already inside the section in place for splitting.
            if playheadTime < section.startTime || playheadTime >= section.endTime {
                seek(to: section.startTime)
            }
        }
    }

    func addCameraSection() {
        guard canAddCamera else { return }
        let section = CameraSegment(startTime: playheadTime, endTime: min(cameraGapEnd, playheadTime + 3))
        editProject(actionName: "Add Camera Section") { project in
            project.cameraSegments = (project.resolvedCameraSegments + [section]).sorted { $0.startTime < $1.startTime }
        }
        selectCamera(id: section.id)
    }

    func splitCameraSection() {
        guard canSplitCamera, let section = selectedCamera ?? project.cameraSegment(at: playheadTime) else { return }
        let time = playheadTime
        let right = CameraSegment(startTime: time, endTime: section.endTime, settings: section.settings)
        editProject(actionName: "Split Camera Section") { project in
            var sections = project.resolvedCameraSegments
            guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return }
            sections[index].endTime = time
            sections.insert(right, at: index + 1)
            project.cameraSegments = sections
        }
        selectCamera(id: right.id)
    }

    func deleteCameraSection(id: UUID) {
        editProject(actionName: "Delete Camera Section") { project in
            project.cameraSegments = project.resolvedCameraSegments.filter { $0.id != id }
        }
        if selectedCameraID == id { selectedCameraID = nil }
    }

    func editCameraSettings(actionName: String, updateClipOverrides: Bool = false, _ edit: (inout CameraOverlaySettings) -> Void) {
        let sectionID = selectedCameraID
        editProject(actionName: actionName) { project in
            if let sectionID {
                var sections = project.resolvedCameraSegments
                guard let index = sections.firstIndex(where: { $0.id == sectionID }) else { return }
                var settings = sections[index].settings ?? project.resolvedCameraOverlay
                edit(&settings)
                sections[index].settings = settings
                project.cameraSegments = sections
            } else {
                var settings = project.resolvedCameraOverlay
                edit(&settings)
                project.cameraOverlay = settings
                if updateClipOverrides, var clips = project.cameraSegments {
                    for index in clips.indices {
                        if var override = clips[index].settings {
                            edit(&override)
                            clips[index].settings = override
                        }
                    }
                    project.cameraSegments = clips
                }
            }
        }
    }

    enum CameraTimingEdit { case move, start, end }

    func updateCameraTiming(id: UUID, to time: Double, edge: CameraTimingEdit) {
        guard time.isFinite else { return }
        var sections = project.resolvedCameraSegments.sorted { $0.startTime < $1.startTime }
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let lower = index == 0 ? 0 : sections[index - 1].endTime
        let upper = index == sections.count - 1 ? recordingDuration : sections[index + 1].startTime
        let duration = sections[index].endTime - sections[index].startTime
        switch edge {
        case .move:
            sections[index].startTime = min(max(lower, time), upper - duration)
            sections[index].endTime = sections[index].startTime + duration
        case .start:
            sections[index].startTime = min(max(lower, time), sections[index].endTime - 0.1)
        case .end:
            sections[index].endTime = max(min(upper, time), sections[index].startTime + 0.1)
        }
        project.cameraSegments = sections
    }
}
