import AVFoundation
import CoreImage
import Foundation

struct BuiltVideoComposition {
    let composition: AVVideoComposition
    let compositor: FrameCompositor
}

struct VideoCompositionBuilder {
    private let context = CIContext(options: [
        .cacheIntermediates: true,
        .useSoftwareRenderer: false
    ])

    func build(
        asset: AVAsset,
        project: RecordingProject,
        events: [RecordedInputEvent],
        quality: ExportQuality
    ) -> BuiltVideoComposition {
        let compositor = FrameCompositor(
            project: project,
            events: events,
            quality: quality
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
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        return BuiltVideoComposition(composition: composition, compositor: compositor)
    }
}
