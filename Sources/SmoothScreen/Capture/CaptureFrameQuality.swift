import CoreMedia
import CoreVideo

struct CaptureFrameAdmission {
    let recordingStartTime: CMTime
    private(set) var hasAcceptedVisibleFrame = false

    mutating func presentationTime(for sourceTime: CMTime, isBlank: Bool) -> CMTime? {
        guard !isBlank else { return nil }
        guard !hasAcceptedVisibleFrame else { return sourceTime }
        hasAcceptedVisibleFrame = true
        return recordingStartTime
    }
}

struct CaptureFrameAnalyzer {
    var blankBrightnessThreshold = 3

    func isVisuallyBlank(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return false
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var brightness = 0
        var samples = 0

        for yFraction in 1...4 {
            let y = height * yFraction / 5
            for xFraction in 1...4 {
                let x = width * xFraction / 5
                let pixel = bytes + (y * bytesPerRow) + (x * 4)
                brightness += Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])
                samples += 3
            }
        }

        return samples > 0 && brightness / samples < blankBrightnessThreshold
    }
}
