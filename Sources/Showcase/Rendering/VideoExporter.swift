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
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ExportError.destinationExists
        }

        let project = try projectStore.loadProject(at: projectURL)
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
            parameters.setVolume(1, at: .zero)
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
