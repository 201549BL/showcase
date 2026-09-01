import AVFoundation
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

    private let writerQueue = DispatchQueue(label: "SmoothScreen.AssetWriter")
    private let videoQueue = DispatchQueue(label: "SmoothScreen.VideoCapture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "SmoothScreen.AudioCapture", qos: .userInitiated)

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
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
        includesMicrophone: Bool
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
        self.audioInput = audioInput
        self.microphoneInput = microphoneInput
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

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, isVideo: Bool) {
        guard isRecording, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }

        writerQueue.async { [weak self] in
            guard let self, self.isRecording, let input else { return }
            guard input.isReadyForMoreMediaData else {
                if isVideo {
                    self.droppedVideoFrameCount += 1
                } else {
                    self.droppedAudioSampleCount += 1
                }
                return
            }
            if !input.append(sampleBuffer) {
                self.terminalError = self.writer?.error
                    ?? RecorderError.assetWriterFailed("Failed to append a media sample.")
            }
        }
    }

    private func clearSession() {
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        microphoneInput = nil
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
            guard isCompleteScreenFrame(sampleBuffer) else { return }
            append(sampleBuffer, to: videoInput, isVideo: true)
        case .audio:
            append(sampleBuffer, to: audioInput, isVideo: false)
        case .microphone:
            append(sampleBuffer, to: microphoneInput, isVideo: false)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        terminalError = error
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let statusRawValue = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            return false
        }
        return status == .complete
    }
}

struct CaptureStatistics: Equatable {
    let droppedVideoFrames: Int
    let droppedAudioSamples: Int
}
