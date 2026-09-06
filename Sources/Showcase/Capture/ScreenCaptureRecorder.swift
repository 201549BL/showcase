import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class ScreenCaptureRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case alreadyRecording
        case assetWriterFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already in progress."
            case .assetWriterFailed(let message):
                return "The recording could not be written: \(message)"
            }
        }
    }

    private let writerQueue = DispatchQueue(label: "Showcase.AssetWriter")
    private let videoQueue = DispatchQueue(label: "Showcase.VideoCapture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "Showcase.AudioCapture", qos: .userInitiated)

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var captureFrameLayout: CaptureFrameLayout?
    private var frameAdmission: CaptureFrameAdmission?
    private let frameAnalyzer = CaptureFrameAnalyzer()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var isRecording = false
    private var terminalError: Error?
    private var droppedVideoFrameCount = 0
    private var droppedAudioSampleCount = 0

    func start(
        source: ResolvedCaptureSource,
        descriptor: CaptureSourceDescriptor,
        outputURL: URL,
        startTime: CMTime,
        includesSystemAudio: Bool,
        includesMicrophone: Bool,
        microphoneDeviceID: String? = nil
    ) async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        let width = evenPixelDimension(descriptor.frame.width * descriptor.scaleFactor)
        let height = evenPixelDimension(descriptor.frame.height * descriptor.scaleFactor)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: targetBitRate(width: width, height: height),
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalKey: 120
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        guard writer.canAdd(videoInput) else {
            throw RecorderError.assetWriterFailed("The video encoder configuration is unsupported.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if includesSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000
                ]
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        var microphoneInput: AVAssetWriterInput?
        if includesMicrophone {
            guard #available(macOS 15, *) else {
                throw RecorderError.assetWriterFailed("Microphone capture requires macOS 15 or newer.")
            }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000
                ]
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                microphoneInput = input
            }
        }

        guard writer.startWriting() else {
            throw RecorderError.assetWriterFailed(writer.error?.localizedDescription ?? "Unknown encoder error")
        }
        writer.startSession(atSourceTime: startTime)

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = includesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        if #available(macOS 15, *) {
            configuration.captureMicrophone = includesMicrophone
            configuration.microphoneCaptureDeviceID = microphoneDeviceID
        }

        let stream = SCStream(
            filter: source.contentFilter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if includesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if #available(macOS 15, *), includesMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }

        self.writer = writer
        self.videoInput = videoInput
        self.videoAdaptor = videoAdaptor
        self.audioInput = audioInput
        self.microphoneInput = microphoneInput
        captureFrameLayout = CaptureFrameLayout(
            outputSize: CGSize(width: width, height: height)
        )
        frameAdmission = CaptureFrameAdmission(recordingStartTime: startTime)
        self.stream = stream
        terminalError = nil
        droppedVideoFrameCount = 0
        droppedAudioSampleCount = 0
        isRecording = true

        do {
            try await stream.startCapture()
        } catch {
            isRecording = false
            writer.cancelWriting()
            clearSession()
            throw error
        }
    }

    func stop() async throws -> CaptureStatistics {
        guard isRecording, let stream, let writer else {
            return CaptureStatistics(droppedVideoFrames: 0, droppedAudioSamples: 0)
        }

        isRecording = false
        var captureStopError: Error?
        do {
            try await stream.stopCapture()
        } catch {
            captureStopError = error
        }
        writerQueue.sync {}

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        microphoneInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        let result = CaptureStatistics(
            droppedVideoFrames: droppedVideoFrameCount,
            droppedAudioSamples: droppedAudioSampleCount
        )
        let writerError = writer.error
        let streamError = terminalError
        clearSession()

        if let captureStopError { throw captureStopError }
        if let streamError { throw streamError }
        if writer.status != .completed {
            throw RecorderError.assetWriterFailed(
                writerError?.localizedDescription ?? "The encoder did not finish successfully."
            )
        }
        return result
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer, frame: ScreenFrame) {
        guard isRecording, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }

        writerQueue.async { [weak self] in
            guard
                let self,
                self.isRecording,
                let input = self.videoInput,
                let adaptor = self.videoAdaptor,
                let layout = self.captureFrameLayout,
                let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                let pool = adaptor.pixelBufferPool
            else { return }
            guard input.isReadyForMoreMediaData else {
                self.droppedVideoFrameCount += 1
                return
            }
            guard let presentationTime = self.frameAdmission?.presentationTime(
                for: sampleBuffer.presentationTimeStamp,
                isBlank: frame.isVisuallyBlank
            ) else { return }

            var destinationBuffer: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer) == kCVReturnSuccess,
                let destinationBuffer
            else {
                self.droppedVideoFrameCount += 1
                return
            }

            let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
            let frameRect = layout.pixelContentRect(
                metadataRect: frame.contentRect,
                scaleFactor: frame.scaleFactor,
                imageExtent: sourceImage.extent
            )
            let normalizedImage = sourceImage
                .cropped(to: frameRect)
                .transformed(by: layout.transformToFill(contentRect: frameRect))
                .cropped(to: CGRect(origin: .zero, size: layout.outputSize))
            self.imageContext.render(normalizedImage, to: destinationBuffer)

            if !adaptor.append(
                destinationBuffer,
                withPresentationTime: presentationTime
            ) {
                self.terminalError = self.writer?.error
                    ?? RecorderError.assetWriterFailed("Failed to append a media sample.")
            }
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard isRecording, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }

        writerQueue.async { [weak self] in
            guard let self, self.isRecording, let input else { return }
            guard input.isReadyForMoreMediaData else {
                self.droppedAudioSampleCount += 1
                return
            }
            if !input.append(sampleBuffer) {
                self.terminalError = self.writer?.error
                    ?? RecorderError.assetWriterFailed("Failed to append an audio sample.")
            }
        }
    }

    private func clearSession() {
        stream = nil
        writer = nil
        videoInput = nil
        videoAdaptor = nil
        audioInput = nil
        microphoneInput = nil
        captureFrameLayout = nil
        frameAdmission = nil
    }

    private func evenPixelDimension(_ value: Double) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded.isMultiple(of: 2) ? rounded : rounded + 1
    }

    private func targetBitRate(width: Int, height: Int) -> Int {
        let pixelsPerSecond = Double(width * height * 60)
        return Int(min(60_000_000, max(8_000_000, pixelsPerSecond * 0.12)))
    }
}

extension ScreenCaptureRecorder: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .screen:
            guard let frame = completeScreenFrame(sampleBuffer) else { return }
            appendVideo(sampleBuffer, frame: frame)
        case .audio:
            appendAudio(sampleBuffer, to: audioInput)
        case .microphone:
            appendAudio(sampleBuffer, to: microphoneInput)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        terminalError = error
    }

    private func completeScreenFrame(_ sampleBuffer: CMSampleBuffer) -> ScreenFrame? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let statusRawValue = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            return nil
        }
        guard status == .complete else { return nil }

        let contentRect: CGRect?
        if let rect = attachments.first?[.contentRect] as? CGRect {
            contentRect = rect
        } else if
            let dictionary = attachments.first?[.contentRect] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: dictionary)
        {
            contentRect = rect
        } else {
            contentRect = nil
        }
        let scaleFactor = (attachments.first?[.scaleFactor] as? NSNumber)?.doubleValue ?? 1
        let isVisuallyBlank = CMSampleBufferGetImageBuffer(sampleBuffer)
            .map(frameAnalyzer.isVisuallyBlank) ?? false
        return ScreenFrame(
            contentRect: contentRect,
            scaleFactor: scaleFactor,
            isVisuallyBlank: isVisuallyBlank
        )
    }
}

private struct ScreenFrame {
    let contentRect: CGRect?
    let scaleFactor: Double
    let isVisuallyBlank: Bool
}

struct CaptureStatistics: Equatable {
    let droppedVideoFrames: Int
    let droppedAudioSamples: Int
}
