import AVFoundation
import CoreImage
import Foundation

struct BuiltVideoComposition {
    let composition: AVVideoComposition
    let compositor: FrameCompositor
}

struct VideoCompositionBuilder {
    enum Purpose {
        case preview
        case export
    }

    private let context = CIContext(options: [
        .cacheIntermediates: true,
        .useSoftwareRenderer: false
    ])

    func build(
        asset: AVAsset,
        project: RecordingProject,
        events: [RecordedInputEvent],
        quality: ExportQuality,
        purpose: Purpose = .export,
        cameraVideoURL: URL? = nil
    ) -> BuiltVideoComposition {
        let maximumCanvasDimension: Double? = purpose == .preview ? 1_280 : nil
        let compositor = FrameCompositor(
            project: project,
            events: events,
            quality: quality,
            maximumCanvasDimension: maximumCanvasDimension,
            cameraFrameProvider: cameraVideoURL.map(AssetCameraFrameProvider.init)
        )
        let composition = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                let rendered = compositor.render(
                    sourceImage: request.sourceImage,
                    at: request.compositionTime
                )
                request.finish(with: rendered, context: context)
            }
        )
        composition.renderSize = compositor.renderSize
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        return BuiltVideoComposition(composition: composition, compositor: compositor)
    }
}
