import Foundation

extension EditorModel {
    var selectedCameraEmphasis: CameraEmphasis? {
        project.cameraTimelineEmphases.first { $0.id == selectedCameraEmphasisID }
    }

    var showsCameraEmphasisTrack: Bool { project.hasCamera && !project.cameraTimelineEmphases.isEmpty }
    var cameraTimelineExtraHeight: CGFloat {
        (project.hasCamera ? 52 : 0) + (showsCameraEmphasisTrack ? 44 : 0)
    }

    var canAddCameraEmphasis: Bool {
        guard project.cameraSettings(at: playheadTime) != nil, playheadTime >= trimStart else { return false }
        return emphasisGapEnd - playheadTime >= 0.1
            && !project.resolvedCameraEmphases.contains { playheadTime >= $0.startTime && playheadTime < $0.endTime }
    }

    private var emphasisGapEnd: Double {
        min(trimEnd, min(project.cameraSegment(at: playheadTime)?.endTime ?? trimEnd,
            project.resolvedCameraEmphases.filter { $0.startTime > playheadTime }.map(\.startTime).min() ?? trimEnd))
    }

    func addCameraEmphasis() {
        guard canAddCameraEmphasis else { return }
        let normalSize = project.cameraSettings(at: playheadTime)?.size ?? 0.22
        let effect = CameraEmphasis(startTime: playheadTime, endTime: min(emphasisGapEnd, playheadTime + 2.5),
                                    targetSize: min(0.6, max(normalSize + 0.12, normalSize * 1.5)))
        editProject(actionName: "Add Camera Effect") { project in
            project.cameraEmphases = (project.resolvedCameraEmphases + [effect]).sorted { $0.startTime < $1.startTime }
        }
        selectCameraEmphasis(id: effect.id)
    }

    func selectCameraEmphasis(id: UUID, seekToPeak: Bool = true) {
        selectedCameraEmphasisID = id
        player.pause()
        if seekToPeak, let effect = selectedCameraEmphasis { seek(to: effect.peakTime) }
    }

    func useRecommendedCameraBehavior() {
        editProject(actionName: "Generate Camera Effects") { project in
            var settings = project.resolvedCameraOverlay
            settings.sizingMode = .adaptive
            project.cameraOverlay = settings
            if var clips = project.cameraSegments {
                for index in clips.indices where clips[index].settings != nil {
                    clips[index].settings?.sizingMode = .adaptive
                }
                project.cameraSegments = clips
            }
            project.suppressedAutomaticCameraZoomIDs = nil
        }
    }

    func deleteCameraEmphasis(id: UUID) {
        editProject(actionName: "Delete Camera Effect") { project in
            project.detachCameraEffect(id: id)
            project.cameraEmphases = project.resolvedCameraEmphases.filter { $0.id != id }
        }
        if selectedCameraEmphasisID == id { selectedCameraEmphasisID = nil }
    }

    func editCameraEmphasis(id: UUID, actionName: String, _ edit: (inout CameraEmphasis) -> Void) {
        editProject(actionName: actionName) { project in
            project.detachCameraEffect(id: id)
            var effects = project.resolvedCameraEmphases
            guard let index = effects.firstIndex(where: { $0.id == id }) else { return }
            edit(&effects[index])
            project.cameraEmphases = effects
        }
    }

    func updateCameraEmphasisTiming(id: UUID, to time: Double, edge: CameraTimingEdit) {
        guard time.isFinite else { return }
        project.detachCameraEffect(id: id)
        var effects = project.resolvedCameraEmphases.sorted { $0.startTime < $1.startTime }
        guard let index = effects.firstIndex(where: { $0.id == id }) else { return }
        let lower = index == 0 ? 0 : effects[index - 1].endTime
        let upper = index == effects.count - 1 ? recordingDuration : effects[index + 1].startTime
        let duration = effects[index].endTime - effects[index].startTime
        switch edge {
        case .move:
            effects[index].startTime = min(max(lower, time), upper - duration)
            effects[index].endTime = effects[index].startTime + duration
        case .start:
            effects[index].startTime = min(max(lower, time), effects[index].endTime - 0.1)
        case .end:
            effects[index].endTime = max(min(upper, time), effects[index].startTime + 0.1)
        }
        project.cameraEmphases = effects
    }
}
