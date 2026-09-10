import AVFoundation
import Foundation

final class VideoExporter {
    enum ExportError: LocalizedError {
        case destinationExists
        case exportSessionUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .destinationExists:
                return "A file already exists at the export destination."
            case .exportSessionUnavailable:
                return "macOS could not create a compatible video export session."
            case .exportFailed(let message):
                return "Video export failed: \(message)"
            }
        }
    }

    private let projectStore: ProjectStore

    init(projectStore: ProjectStore = ProjectStore()) {
        self.projectStore = projectStore
    }

    func export(
        projectURL: URL,
        destinationURL: URL,
        quality: ExportQuality
    ) async throws {
        let project = try projectStore.loadProject(at: projectURL)
        try await export(project: project, projectURL: projectURL, destinationURL: destinationURL, quality: quality)
    }

    /// Export a snapshot of the project sequentially, keeping rendering memory bounded.
    func exportBatch(
        projectURL: URL,
        directoryURL: URL,
        formats: [CanvasSettings.AspectRatio],
        quality: ExportQuality,
        didExport: (URL) -> Void = { _ in }
    ) async throws -> [URL] {
        let snapshot = try projectStore.loadProject(at: projectURL)
        var outputs: [URL] = []
        var seen = Set<CanvasSettings.AspectRatio>()
        for format in formats where seen.insert(format).inserted {
            var project = snapshot
            project.canvas.aspectRatio = format
            let name = projectURL.deletingPathExtension().lastPathComponent
                + "-" + format.filenameSuffix + "-" + quality.displayName
            var destination = directoryURL.appendingPathComponent(name + ".mp4")
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = directoryURL.appendingPathComponent("\(name)-\(suffix).mp4")
                suffix += 1
            }
            try await export(project: project, projectURL: projectURL,
                             destinationURL: destination, quality: quality)
            outputs.append(destination)
            didExport(destination)
        }
        return outputs
    }

    private func export(
        project: RecordingProject,
        projectURL: URL,
        destinationURL: URL,
        quality: ExportQuality
    ) async throws {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ExportError.destinationExists
        }

        let events = try projectStore.loadEvents(at: projectURL)
        let locations = projectStore.locations(for: projectURL)
        let asset = AVURLAsset(url: locations.videoURL)
        let built = VideoCompositionBuilder().build(
            asset: asset,
            project: project,
            events: events,
            quality: quality,
            cameraVideoURL: project.recording.cameraVideoRelativePath == nil
                ? nil
                : locations.cameraVideoURL,
            projectURL: projectURL
        )

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exportSessionUnavailable
        }

        session.outputURL = destinationURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = built.composition
        let sourceDuration = try await asset.load(.duration)
        let sourceDurationSeconds = max(0, CMTimeGetSeconds(sourceDuration))
        let trimStart = max(0, min(sourceDurationSeconds, project.timeline?.trimStart ?? 0))
        let trimEnd = max(
            trimStart,
            min(sourceDurationSeconds, project.timeline?.trimEnd ?? sourceDurationSeconds)
        )
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            duration: CMTime(seconds: trimEnd - trimStart, preferredTimescale: 600)
        )
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioParameters = audioTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(project.resolvedIsAudioMuted ? 0 : 1, at: .zero)
            return parameters
        }
        if !audioParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioParameters
            session.audioMix = audioMix
        }

        await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        guard session.status == .completed else {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            throw ExportError.exportFailed(
                session.error?.localizedDescription ?? "The exporter ended with status \(session.status.rawValue)."
            )
        }
    }
}
