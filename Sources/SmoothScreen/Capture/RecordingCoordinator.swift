import CoreMedia
import Foundation

final class RecordingCoordinator {
    enum CoordinatorError: LocalizedError {
        case notRecording

        var errorDescription: String? {
            "There is no active recording to stop."
        }
    }

    private let projectStore: ProjectStore
    private let sourceService: CaptureSourceService
    private let screenRecorder: ScreenCaptureRecorder
    private let inputRecorder: InputEventRecorder

    private var activeProject: RecordingProject?
    private var activeLocations: ProjectLocations?
    private var recordingStartTime: CMTime?

    init(
        projectStore: ProjectStore = ProjectStore(),
        sourceService: CaptureSourceService = CaptureSourceService(),
        screenRecorder: ScreenCaptureRecorder = ScreenCaptureRecorder(),
        inputRecorder: InputEventRecorder = InputEventRecorder()
    ) {
        self.projectStore = projectStore
        self.sourceService = sourceService
        self.screenRecorder = screenRecorder
        self.inputRecorder = inputRecorder
    }

    func start(
        source descriptor: CaptureSourceDescriptor,
        includesSystemAudio: Bool,
        includesMicrophone: Bool
    ) async throws -> URL {
        let resolvedSource = try await sourceService.resolve(descriptor)
        let locations = try projectStore.createProjectDirectory(named: projectName())
        let width = evenPixelDimension(descriptor.frame.width * descriptor.scaleFactor)
        let height = evenPixelDimension(descriptor.frame.height * descriptor.scaleFactor)

        let metadata = RecordingMetadata(
            source: descriptor,
            width: width,
            height: height,
            framesPerSecond: 60,
            duration: nil,
            includesSystemAudio: includesSystemAudio,
            includesMicrophone: includesMicrophone,
            videoRelativePath: "media/screen.mov",
            eventsRelativePath: "events/input-events.json"
        )
        let project = RecordingProject(recording: metadata)
        try projectStore.save(project, to: locations)

        let startTime = CMClockGetTime(CMClockGetHostTimeClock())
        do {
            try inputRecorder.start(at: startTime, source: descriptor)
            try await screenRecorder.start(
                source: resolvedSource,
                descriptor: descriptor,
                outputURL: locations.videoURL,
                startTime: startTime,
                includesSystemAudio: includesSystemAudio,
                includesMicrophone: includesMicrophone
            )
        } catch {
            _ = inputRecorder.stop()
            throw error
        }

        activeProject = project
        activeLocations = locations
        recordingStartTime = startTime
        return locations.projectURL
    }

    func stop() async throws -> CompletedRecording {
        guard
            var project = activeProject,
            let locations = activeLocations,
            let startTime = recordingStartTime
        else {
            throw CoordinatorError.notRecording
        }

        let captureResult: Result<CaptureStatistics, Error>
        do {
            captureResult = .success(try await screenRecorder.stop())
        } catch {
            captureResult = .failure(error)
        }
        let events = inputRecorder.stop()
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())
        let duration = max(0, CMTimeGetSeconds(CMTimeSubtract(endTime, startTime)))

        project.completedAt = Date()
        project.recording.duration = duration
        project.timeline = TimelineSettings(trimStart: 0, trimEnd: duration)
        let localizedEvents = InputEventLocalizer().localize(
            events,
            source: project.recording.source,
            pixelWidth: project.recording.width,
            pixelHeight: project.recording.height
        )
        let zoomBehavior = project.resolvedZoomBehavior
        project.zoomSegments = zoomBehavior.preset == .off
            ? []
            : AutoZoomPlanner(settings: zoomBehavior).plan(
                events: localizedEvents,
                sourceSize: CGSize(
                    width: project.recording.width,
                    height: project.recording.height
                ),
                duration: duration
            )
        try projectStore.save(events: events, to: locations)
        try projectStore.save(project, to: locations)

        activeProject = nil
        activeLocations = nil
        recordingStartTime = nil

        let statistics = try captureResult.get()

        return CompletedRecording(
            projectURL: locations.projectURL,
            duration: duration,
            eventCount: events.count,
            statistics: statistics
        )
    }

    private func projectName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Recording \(formatter.string(from: Date()))"
    }

    private func evenPixelDimension(_ value: Double) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded.isMultiple(of: 2) ? rounded : rounded + 1
    }
}

struct CompletedRecording: Equatable {
    let projectURL: URL
    let duration: Double
    let eventCount: Int
    let statistics: CaptureStatistics
}
