import AVFoundation
import CoreImage
import CoreMedia
import Foundation

protocol CameraFrameProviding: AnyObject {
    func frame(at time: CMTime) -> CIImage?
}

final class AssetCameraFrameProvider: CameraFrameProviding {
    private let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var cachedFrames: [Int64: CIImage] = [:]
    private var cacheOrder: [Int64] = []

    init(url: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_280, height: 720)
        let tolerance = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
    }

    func frame(at time: CMTime) -> CIImage? {
        let frameNumber = Int64((max(0, CMTimeGetSeconds(time)) * 30).rounded())
        return lock.withLock {
            if let cached = cachedFrames[frameNumber] { return cached }

            let requestedTime = CMTime(value: frameNumber, timescale: 30)
            guard let image = try? generator.copyCGImage(at: requestedTime, actualTime: nil) else {
                return nil
            }
            let frame = CIImage(cgImage: image)
            cachedFrames[frameNumber] = frame
            cacheOrder.append(frameNumber)
            if cacheOrder.count > 12 {
                cachedFrames.removeValue(forKey: cacheOrder.removeFirst())
            }
            return frame
        }
    }
}
