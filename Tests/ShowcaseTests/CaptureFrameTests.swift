import CoreGraphics
import CoreMedia
import CoreVideo
import Testing
@testable import Showcase

@Suite("Capture frame normalization")
struct CaptureFrameTests {
    @Test("A temporarily reduced content rectangle fills the recording frame")
    func reducedContentFillsOutput() {
        let layout = CaptureFrameLayout(outputSize: CGSize(width: 1_600, height: 900))
        let reducedContent = CGRect(x: 200, y: 112.5, width: 1_200, height: 675)

        let normalizedContent = reducedContent.applying(
            layout.transformToFill(contentRect: reducedContent)
        )

        #expect(abs(normalizedContent.minX) < 0.001)
        #expect(abs(normalizedContent.minY) < 0.001)
        #expect(abs(normalizedContent.width - 1_600) < 0.001)
        #expect(abs(normalizedContent.height - 900) < 0.001)
    }

    @Test("Retina content metadata is converted from points to pixels")
    func retinaContentRectUsesScaleFactor() {
        let layout = CaptureFrameLayout(outputSize: CGSize(width: 460, height: 816))

        let pixelRect = layout.pixelContentRect(
            metadataRect: CGRect(x: 0, y: 0, width: 230, height: 408),
            scaleFactor: 2,
            imageExtent: CGRect(x: 0, y: 0, width: 460, height: 816)
        )

        #expect(pixelRect == CGRect(x: 0, y: 0, width: 460, height: 816))
    }

    @Test("Blank transition frames are held until visible content returns")
    func transientBlankFramesAreSuppressed() {
        let start = CMTime(seconds: 10, preferredTimescale: 600)
        var admission = CaptureFrameAdmission(recordingStartTime: start)

        #expect(admission.presentationTime(for: start + CMTime(seconds: 0.1, preferredTimescale: 600), isBlank: true) == nil)
        #expect(admission.presentationTime(for: start + CMTime(seconds: 1, preferredTimescale: 600), isBlank: false) == start)
        #expect(admission.presentationTime(for: start + CMTime(seconds: 2, preferredTimescale: 600), isBlank: true) == nil)
        #expect(
            admission.presentationTime(
                for: start + CMTime(seconds: 3, preferredTimescale: 600),
                isBlank: false
            ) == start + CMTime(seconds: 3, preferredTimescale: 600)
        )
    }

    @Test("Pixel analysis distinguishes blank surfaces from dark content")
    func detectsBlankPixelBuffers() throws {
        let analyzer = CaptureFrameAnalyzer()
        let black = try pixelBuffer(filledWith: 0)
        let darkGray = try pixelBuffer(filledWith: 12)

        #expect(analyzer.isVisuallyBlank(black))
        #expect(!analyzer.isVisuallyBlank(darkGray))
    }

    private func pixelBuffer(filledWith value: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            nil,
            20,
            20,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        #expect(result == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let byteCount = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(value), byteCount)
        return buffer
    }
}
