import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import SmoothScreen

@Suite("Editor viewbox interaction")
struct EditorModelViewboxTests {
    @Test("Dragging the viewbox does not replace the player item while editing")
    @MainActor
    func viewboxEditKeepsPlayerStable() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = ProjectStore(projectsDirectory: temporaryRoot)
        let locations = try store.createProjectDirectory(named: "Viewbox Fixture")
        try await createFixtureVideo(at: locations.videoURL)

        let zoomID = UUID()
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
                videoRelativePath: "media/screen.mov",
                eventsRelativePath: "events/input-events.json"
            )
        )
        project.zoomSegments = [
            ZoomSegment(
                id: zoomID,
                startTime: 0,
                focusTime: 0.5,
                endTime: 1,
                focusPoint: CodablePoint(CGPoint(x: 160, y: 90)),
                scale: 1.5,
                source: .manual
            )
        ]
        try store.save(project, to: locations)
        try store.save(events: [], to: locations)

        let model = try EditorModel(projectURL: locations.projectURL, projectStore: store)
        let audioPlayerItem = model.player.currentItem
        model.setAudioMuted(true)
        #expect(model.player.isMuted)
        #expect(model.player.currentItem === audioPlayerItem)
        #expect(try store.loadProject(at: locations.projectURL).resolvedIsAudioMuted)
        model.undo()
        #expect(!model.player.isMuted)
        model.redo()
        #expect(model.player.isMuted)
        model.setAudioMuted(false)
        #expect(!model.player.isMuted)
        let initialZoom = try #require(model.selectedZoom)
        let initialPositions = model.cameraPositions(for: initialZoom)
        #expect(initialPositions.map(\.id) == [zoomID])
        #expect(initialPositions.first?.isInitial == true)

        model.setViewboxEditing(true)
        let playerItem = try #require(model.player.currentItem)

        model.setSelectedZoomViewbox(
            focusPoint: CGPoint(x: 180, y: 100),
            scale: 1.7
        )
        try await Task.sleep(for: .milliseconds(300))

        #expect(model.selectedZoom?.focusPoint.cgPoint == CGPoint(x: 180, y: 100))
        #expect(model.selectedZoom?.scale == 1.7)
        #expect(model.player.currentItem === playerItem)

        model.seek(to: 0.7)
        let reframeID = try #require(model.addReframeAtPlayhead(to: zoomID))
        model.setSelectedZoomViewbox(
            focusPoint: CGPoint(x: 200, y: 110),
            scale: 1.8
        )

        let reframe = try #require(
            model.selectedZoom?.reframes.first(where: { $0.id == reframeID })
        )
        let positions = model.cameraPositions(for: try #require(model.selectedZoom))
        #expect(positions.map(\.id) == [zoomID, reframeID])
        #expect(positions.map(\.isInitial) == [true, false])
        #expect(reframe.focusPoint.cgPoint == CGPoint(x: 200, y: 110))
        #expect(reframe.scale == 1.8)
        #expect(model.selectedZoom?.focusPoint.cgPoint == CGPoint(x: 180, y: 100))
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
        guard writer.canAdd(input) else { throw FixtureError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.cannotStartWriting }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw FixtureError.noPixelBufferPool }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { throw FixtureError.noPixelBuffer }
        let image = CIImage(
            color: CIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        CIContext().render(image, to: pixelBuffer)

        for frame in [0, 29] {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: Int64(frame), timescale: 30)
            ) else {
                throw writer.error ?? FixtureError.cannotAppendFrame
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? FixtureError.cannotFinishWriting
        }
    }
}

private enum FixtureError: Error {
    case cannotAddInput
    case cannotStartWriting
    case noPixelBufferPool
    case noPixelBuffer
    case cannotAppendFrame
    case cannotFinishWriting
}
