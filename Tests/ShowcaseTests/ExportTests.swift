import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import Showcase

@Suite("Video export")
struct ExportTests {
    @Test("Exports a composed MP4 with the expected dimensions")
    @MainActor
    func exportsComposedVideo() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let projectsRoot = temporaryRoot.appendingPathComponent("Projects", isDirectory: true)
        let store = ProjectStore(projectsDirectory: projectsRoot)
        let locations = try store.createProjectDirectory(named: "Export Fixture")
        try await createFixtureVideo(at: locations.videoURL)

        let source = CaptureSourceDescriptor(
            kind: .display,
            sourceID: 1,
            title: "Fixture",
            applicationName: nil,
            frame: CodableRect(CGRect(x: 0, y: 0, width: 320, height: 180)),
            scaleFactor: 1
        )
        var project = RecordingProject(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            recording: RecordingMetadata(
                source: source,
                width: 320,
                height: 180,
                framesPerSecond: 30,
                duration: 1,
                includesSystemAudio: false,
                includesMicrophone: false,
                videoRelativePath: "media/screen.mov",
                eventsRelativePath: "events/input-events.json"
            )
        )
        project.canvas.aspectRatio = .source
        project.timeline = TimelineSettings(trimStart: 0.2, trimEnd: 0.8)
        project.zoomSegments = [
            ZoomSegment(
                id: UUID(),
                startTime: 0.1,
                focusTime: 0.3,
                endTime: 0.8,
                focusPoint: CodablePoint(CGPoint(x: 160, y: 90)),
                scale: 1.4,
                source: .automatic
            )
        ]
        let events = [
            inputEvent(time: 0, type: .mouseMoved, point: CGPoint(x: 20, y: 20)),
            inputEvent(time: 0.25, type: .leftMouseDown, point: CGPoint(x: 160, y: 90)),
            inputEvent(time: 0.7, type: .mouseMoved, point: CGPoint(x: 240, y: 120))
        ]
        try store.save(project, to: locations)
        try store.save(events: events, to: locations)

        let outputURL = temporaryRoot.appendingPathComponent("output.mp4")
        try await VideoExporter(projectStore: store).export(
            projectURL: locations.projectURL,
            destinationURL: outputURL,
            quality: .hd
        )

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 1_000)

        let outputAsset = AVURLAsset(url: outputURL)
        let tracks = try await outputAsset.loadTracks(withMediaType: .video)
        let naturalSize = try await tracks[0].load(.naturalSize)
        let outputDuration = CMTimeGetSeconds(try await outputAsset.load(.duration))
        #expect(naturalSize == CGSize(width: 320, height: 180))
        #expect(outputDuration > 0.55 && outputDuration < 0.7)

        let frameTimes = try framePresentationTimes(asset: outputAsset, track: tracks[0])
            .sorted()
        #expect(frameTimes.count >= 32)
        let largestFrameGap = zip(frameTimes, frameTimes.dropFirst())
            .map { CMTimeGetSeconds($1 - $0) }
            .max() ?? 0
        #expect(largestFrameGap < 0.025)

        if ProcessInfo.processInfo.environment["SHOWCASE_KEEP_FIXTURE"] == "1" {
            let retained = URL(fileURLWithPath: ".build/export-fixture.mp4")
            try? FileManager.default.removeItem(at: retained)
            try FileManager.default.copyItem(at: outputURL, to: retained)

            let retainedProject = URL(fileURLWithPath: ".build/ExportFixture.screenproject")
            try? FileManager.default.removeItem(at: retainedProject)
            try FileManager.default.copyItem(at: locations.projectURL, to: retainedProject)
        }
    }

    private func framePresentationTimes(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        #expect(reader.canAdd(output))
        reader.add(output)
        #expect(reader.startReading())

        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        #expect(reader.status == .completed)
        return times
    }

    private func createFixtureVideo(at url: URL) async throws {
        let width = 320
        let height = 180
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
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                await Task.yield()
            }
            guard let pool = adaptor.pixelBufferPool else {
                Issue.record("Pixel buffer pool was not created")
                return
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else {
                Issue.record("Pixel buffer allocation failed")
                return
            }

            let progress = Double(frame) / 29
            let image = CIImage(
                color: CIColor(red: 0.1 + progress * 0.6, green: 0.25, blue: 0.8 - progress * 0.5)
            ).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            context.render(image, to: pixelBuffer)
            #expect(
                adaptor.append(
                    pixelBuffer,
                    withPresentationTime: CMTime(value: Int64(frame), timescale: 30)
                )
            )
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        #expect(writer.status == .completed)
    }

    private func inputEvent(
        time: Double,
        type: RecordedInputEvent.EventType,
        point: CGPoint
    ) -> RecordedInputEvent {
        RecordedInputEvent(
            timestamp: time,
            type: type,
            position: CodablePoint(point),
            buttonNumber: 0,
            scrollDeltaX: nil,
            scrollDeltaY: nil,
            keyCode: nil,
            flags: 0
        )
    }
}
