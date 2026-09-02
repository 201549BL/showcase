import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import SmoothScreen

@Suite("Frame compositor")
struct FrameCompositorTests {
    @Test("Composites visible cursor pixels over a source frame")
    func compositesVisibleCursorPixels() throws {
        var project = fixtureProject()
        project.canvas.aspectRatio = .source
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.hideAfter = 10

        let cursorEvent = RecordedInputEvent(
            timestamp: 0,
            type: .mouseMoved,
            position: CodablePoint(CGPoint(x: 160, y: 90)),
            buttonNumber: 0,
            scrollDeltaX: nil,
            scrollDeltaY: nil,
            keyCode: nil,
            flags: 0
        )
        let source = CIImage(
            color: CIColor(red: 0.08, green: 0.42, blue: 0.73, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)

        let withCursor = FrameCompositor(
            project: project,
            events: [cursorEvent],
            quality: .hd
        ).render(sourceImage: source, at: time)
        let withoutCursor = FrameCompositor(
            project: project,
            events: [],
            quality: .hd
        ).render(sourceImage: source, at: time)

        let cursorPixels = rgbaPixels(in: withCursor)
        let baselinePixels = rgbaPixels(in: withoutCursor)
        let changedPixelCount = stride(from: 0, to: cursorPixels.count, by: 4).reduce(into: 0) {
            if cursorPixels[$1..<$1 + 4] != baselinePixels[$1..<$1 + 4] {
                $0 += 1
            }
        }

        #expect(changedPixelCount >= 20)
    }

    @Test("Vertical framing keeps the full cursor bitmap inside the viewport")
    func verticalFramingKeepsFullCursorVisible() {
        var project = fixtureProject()
        project.canvas.aspectRatio = .vertical
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.hideAfter = 10
        project.cursor.smoothing = 0
        project.cursor.showsClickAnimation = false
        project.zoomSegments = [
            ZoomSegment(
                id: UUID(),
                startTime: 0,
                focusTime: 0.4,
                endTime: 2,
                focusPoint: CodablePoint(CGPoint(x: 160, y: 90)),
                scale: 1.75,
                source: .automatic
            )
        ]
        let cursorPosition = CGPoint(x: 160, y: 145)
        let compositor = FrameCompositor(
            project: project,
            events: [
                cursorEvent(timestamp: 0.99, x: 160, y: 90),
                cursorEvent(timestamp: 1, x: cursorPosition.x, y: cursorPosition.y)
            ],
            quality: .hd
        )
        let camera = compositor.cameraState(at: 1)
        let geometry = CanvasGeometry(project: project, quality: .hd)
        let cursorCanvasScale = project.cursor.scale * geometry.canvasSize.height / 1_080
        let cursorBottomFraction = (48 - 2) * cursorCanvasScale
            / (geometry.screenRect.height / 2)
        let visibleHalfHeight = Double(project.recording.height) / (2 * camera.scale)
        let allowedDownwardDelta = visibleHalfHeight * (1 - cursorBottomFraction)
        #expect(cursorPosition.y - camera.focusPoint.y <= allowedDownwardDelta + 0.001)
    }

    @Test("Large vertical cursor uses a one-sided safe viewport region")
    func largeVerticalCursorUsesAsymmetricSafeRegion() {
        var project = fixtureProject()
        project.canvas.aspectRatio = .vertical
        project.canvas.padding = 160
        project.cursor.scale = 2.5
        project.cursor.smoothing = 0
        project.cursor.hideAfter = 10
        project.zoomSegments = [
            ZoomSegment(
                id: UUID(),
                startTime: 0,
                focusTime: 0.4,
                endTime: 2,
                focusPoint: CodablePoint(CGPoint(x: 160, y: 90)),
                scale: 1.75,
                source: .automatic
            )
        ]
        let cursorPosition = CGPoint(x: 160, y: 70)
        let compositor = FrameCompositor(
            project: project,
            events: [cursorEvent(timestamp: 1, x: cursorPosition.x, y: cursorPosition.y)],
            quality: .hd
        )
        let camera = compositor.cameraState(at: 1)
        let geometry = CanvasGeometry(project: project, quality: .hd)
        let cursorCanvasScale = project.cursor.scale * geometry.canvasSize.height / 1_080
        let topInset = 2 * cursorCanvasScale / (geometry.screenRect.height / 2)
        let bottomInset = (48 - 2) * cursorCanvasScale / (geometry.screenRect.height / 2)
        let visibleHalfHeight = Double(project.recording.height) / (2 * camera.scale)
        let allowedRange: ClosedRange<Double> = (
            -visibleHalfHeight * (1 - topInset)
        )...(
            visibleHalfHeight * (1 - bottomInset)
        )
        let cursorDelta = Double(cursorPosition.y - camera.focusPoint.y)

        #expect(allowedRange.upperBound < 0)
        #expect(cursorDelta >= allowedRange.lowerBound - 0.001)
        #expect(cursorDelta <= allowedRange.upperBound + 0.001)
    }

    @Test("AVPlayer preview preserves off-center cursor pixels at reduced preview size")
    @MainActor
    func playerPreviewPreservesCursorPixels() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let videoURL = temporaryRoot.appendingPathComponent("static.mov")
        try await createStaticFixtureVideo(at: videoURL, width: 320, height: 180)

        var project = RecordingProject(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            recording: RecordingMetadata(
                source: CaptureSourceDescriptor(
                    kind: .display,
                    sourceID: 1,
                    title: "Fixture",
                    applicationName: nil,
                    frame: CodableRect(CGRect(x: 0, y: 0, width: 320, height: 180)),
                    scaleFactor: 1
                ),
                width: 320,
                height: 180,
                framesPerSecond: 30,
                duration: 1,
                includesSystemAudio: false,
                includesMicrophone: false,
                videoRelativePath: "static.mov",
                eventsRelativePath: "events.json"
            )
        )
        project.canvas.aspectRatio = .landscape
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.hideAfter = 30
        project.cursor.showsClickAnimation = false
        let cursorEvent = RecordedInputEvent(
            timestamp: 0,
            type: .mouseMoved,
            position: CodablePoint(CGPoint(x: 240, y: 90)),
            buttonNumber: 0,
            scrollDeltaX: nil,
            scrollDeltaY: nil,
            keyCode: nil,
            flags: 0
        )
        let asset = AVURLAsset(url: videoURL)

        let visibleComposition = VideoCompositionBuilder().build(
            asset: asset,
            project: project,
            events: [cursorEvent],
            quality: .hd,
            purpose: .preview
        ).composition
        let hiddenComposition = VideoCompositionBuilder().build(
            asset: asset,
            project: project,
            events: [],
            quality: .hd,
            purpose: .preview
        ).composition
        #expect(visibleComposition.renderScale == 1)
        #expect(visibleComposition.renderSize == CGSize(width: 1_280, height: 720))

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let visiblePixels = try await playerPixels(
            asset: asset,
            composition: visibleComposition,
            at: time
        )
        let hiddenPixels = try await playerPixels(
            asset: asset,
            composition: hiddenComposition,
            at: time
        )
        #expect(visiblePixels.count == hiddenPixels.count)
        let changedPixelCount = stride(from: 0, to: visiblePixels.count, by: 4).reduce(into: 0) {
            if visiblePixels[$1..<$1 + 4] != hiddenPixels[$1..<$1 + 4] {
                $0 += 1
            }
        }

        #expect(changedPixelCount >= 100)
    }

    @Test("Preview canvas cap does not reduce full-quality exports")
    @MainActor
    func previewCanvasCapDoesNotLeakIntoExports() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let videoURL = temporaryRoot.appendingPathComponent("static.mov")
        try await createStaticFixtureVideo(at: videoURL, width: 320, height: 180)

        var project = fixtureProject()
        project.canvas.aspectRatio = .landscape
        let asset = AVURLAsset(url: videoURL)
        let cases: [(ExportQuality, CGSize)] = [
            (.hd, CGSize(width: 1_920, height: 1_080)),
            (.ultraHD, CGSize(width: 3_840, height: 2_160))
        ]

        for (quality, expectedExportSize) in cases {
            let preview = VideoCompositionBuilder().build(
                asset: asset,
                project: project,
                events: [],
                quality: quality,
                purpose: .preview
            )
            let export = VideoCompositionBuilder().build(
                asset: asset,
                project: project,
                events: [],
                quality: quality
            )

            #expect(preview.composition.renderSize == CGSize(width: 1_280, height: 720))
            #expect(preview.composition.renderScale == 1)
            #expect(export.composition.renderSize == expectedExportSize)
            #expect(export.compositor.renderSize == expectedExportSize)
            #expect(export.composition.renderScale == 1)
        }
    }

    private func fixtureProject() -> RecordingProject {
        RecordingProject(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            recording: RecordingMetadata(
                source: CaptureSourceDescriptor(
                    kind: .display,
                    sourceID: 1,
                    title: "Fixture",
                    applicationName: nil,
                    frame: CodableRect(CGRect(x: 0, y: 0, width: 320, height: 180)),
                    scaleFactor: 1
                ),
                width: 320,
                height: 180,
                framesPerSecond: 60,
                duration: 1,
                includesSystemAudio: false,
                includesMicrophone: false,
                videoRelativePath: "media/screen.mov",
                eventsRelativePath: "events/input-events.json"
            )
        )
    }

    private func cursorEvent(
        timestamp: Double = 0,
        x: Double,
        y: Double
    ) -> RecordedInputEvent {
        RecordedInputEvent(
            timestamp: timestamp,
            type: .mouseMoved,
            position: CodablePoint(CGPoint(x: x, y: y)),
            buttonNumber: 0,
            scrollDeltaX: nil,
            scrollDeltaY: nil,
            keyCode: nil,
            flags: 0
        )
    }

    private func rgbaPixels(in image: CIImage) -> [UInt8] {
        let bounds = image.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        pixels.withUnsafeMutableBytes { buffer in
            context.render(
                image,
                toBitmap: buffer.baseAddress!,
                rowBytes: rowBytes,
                bounds: bounds,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        return pixels
    }

    @MainActor
    private func playerPixels(
        asset: AVAsset,
        composition: AVVideoComposition,
        at time: CMTime
    ) async throws -> [UInt8] {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = composition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
        player.playImmediately(atRate: 1)
        defer { player.pause() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            let itemTime = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: itemTime) {
                if let pixelBuffer = output.copyPixelBuffer(
                    forItemTime: itemTime,
                    itemTimeForDisplay: nil
                ) {
                    return bgraPixels(in: pixelBuffer)
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PreviewHarnessError.noFrame
    }

    private func bgraPixels(in pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let outputRowBytes = width * 4
        let source = CVPixelBufferGetBaseAddress(pixelBuffer)!
        var pixels = [UInt8](repeating: 0, count: outputRowBytes * height)
        pixels.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                destination.baseAddress!
                    .advanced(by: row * outputRowBytes)
                    .copyMemory(
                        from: source.advanced(by: row * sourceRowBytes),
                        byteCount: outputRowBytes
                    )
            }
        }
        return pixels
    }

    private func createStaticFixtureVideo(at url: URL, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw PreviewHarnessError.writerConfigurationUnsupported
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? PreviewHarnessError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw PreviewHarnessError.noPixelBufferPool
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { throw PreviewHarnessError.noPixelBuffer }
        let source = CIImage(
            color: CIColor(red: 0.08, green: 0.42, blue: 0.73, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        CIContext().render(source, to: pixelBuffer)

        let clock = ContinuousClock()
        for frame in [0, 29] {
            let deadline = clock.now.advanced(by: .seconds(2))
            while !input.isReadyForMoreMediaData, clock.now < deadline {
                await Task.yield()
            }
            guard input.isReadyForMoreMediaData else {
                throw PreviewHarnessError.writerNotReady
            }
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: Int64(frame), timescale: 30)
            ) else {
                throw writer.error ?? PreviewHarnessError.writerAppendFailed
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        #expect(writer.status == .completed)
    }
}

private enum PreviewHarnessError: Error {
    case noFrame
    case noPixelBufferPool
    case noPixelBuffer
    case writerNotReady
    case writerConfigurationUnsupported
    case writerStartFailed
    case writerAppendFailed
}
