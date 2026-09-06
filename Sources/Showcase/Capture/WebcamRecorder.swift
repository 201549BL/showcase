@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

enum CaptureSessionLifecycle {
    static func configureAndStart(
        beginConfiguration: () -> Void,
        configure: () throws -> Void,
        commitConfiguration: () -> Void,
        startRunning: () -> Void
    ) rethrows {
        beginConfiguration()
        var didCommitConfiguration = false
        defer {
            if !didCommitConfiguration {
                commitConfiguration()
            }
        }
        try configure()
        commitConfiguration()
        didCommitConfiguration = true
        startRunning()
    }
}

final class WebcamRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case noCamera
        case configurationFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Camera access is required to record your face. Enable it in System Settings → Privacy & Security → Camera."
            case .noCamera:
                return "No available camera was found."
            case .configurationFailed(let message):
                return "The camera could not be configured: \(message)"
            case .writerFailed(let message):
                return "The camera recording could not be written: \(message)"
            }
        }
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "Showcase.WebcamSession")
    private let writerQueue = DispatchQueue(label: "Showcase.WebcamWriter")
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let outputSize = CGSize(width: 1_280, height: 720)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime = CMTime.zero
    private var isRecording = false
    private var terminalError: Error?

    func start(outputURL: URL, startTime: CMTime, deviceID: String? = nil) async throws {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let isAuthorized: Bool
        if authorization == .notDetermined {
            isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        } else {
            isAuthorized = authorization == .authorized
        }
        guard isAuthorized else { throw RecorderError.permissionDenied }
        let selectedCamera: AVCaptureDevice?
        if let deviceID { selectedCamera = AVCaptureDevice(uniqueID: deviceID) }
        else { selectedCamera = AVCaptureDevice.default(for: .video) }
        guard let camera = selectedCamera else {
            throw RecorderError.noCamera
        }

        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: camera)
        } catch {
            throw RecorderError.configurationFailed(error.localizedDescription)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: writerQueue)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw RecorderError.writerFailed("The camera encoder configuration is unsupported.")
        }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(
                writer.error?.localizedDescription ?? "Unknown encoder error"
            )
        }
        writer.startSession(atSourceTime: startTime)

        self.writer = writer
        self.videoInput = videoInput
        self.videoAdaptor = videoAdaptor
        recordingStartTime = startTime
        terminalError = nil
        isRecording = true

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [session] in
                do {
                    try CaptureSessionLifecycle.configureAndStart(
                        beginConfiguration: { session.beginConfiguration() },
                        configure: {
                            session.sessionPreset = .hd1280x720
                            guard session.canAddInput(deviceInput) else {
                                throw RecorderError.configurationFailed(
                                    "The selected camera input is unavailable."
                                )
                            }
                            session.addInput(deviceInput)
                            guard session.canAddOutput(videoOutput) else {
                                throw RecorderError.configurationFailed(
                                    "The camera video output is unavailable."
                                )
                            }
                            session.addOutput(videoOutput)
                        },
                        commitConfiguration: { session.commitConfiguration() },
                        startRunning: { session.startRunning() }
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws {
        guard isRecording, let writer else { return }
        isRecording = false

        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                session.stopRunning()
                continuation.resume()
            }
        }
        writerQueue.sync {}
        videoInput?.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        let writerError = writer.error
        let captureError = terminalError
        clearSession()
        if let captureError { throw captureError }
        guard writer.status == .completed else {
            throw RecorderError.writerFailed(
                writerError?.localizedDescription ?? "The encoder did not finish successfully."
            )
        }
    }

    func cancel() async {
        isRecording = false
        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
        writerQueue.sync {}
        writer?.cancelWriting()
        clearSession()
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard
            isRecording,
            sampleBuffer.isValid,
            sampleBuffer.presentationTimeStamp >= recordingStartTime,
            let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let videoInput,
            let videoAdaptor,
            let pool = videoAdaptor.pixelBufferPool
        else { return }
        guard videoInput.isReadyForMoreMediaData else { return }

        var destinationBuffer: CVPixelBuffer?
        guard
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer) == kCVReturnSuccess,
            let destinationBuffer
        else { return }

        let source = CIImage(cvPixelBuffer: sourceBuffer)
        let scale = max(
            outputSize.width / source.extent.width,
            outputSize.height / source.extent.height
        )
        let scaled = source.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let cropRect = CGRect(
            x: scaled.extent.midX - outputSize.width / 2,
            y: scaled.extent.midY - outputSize.height / 2,
            width: outputSize.width,
            height: outputSize.height
        )
        let normalized = scaled
            .cropped(to: cropRect)
            .transformed(
                by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
            )
        imageContext.render(normalized, to: destinationBuffer)

        if !videoAdaptor.append(
            destinationBuffer,
            withPresentationTime: sampleBuffer.presentationTimeStamp
        ) {
            terminalError = writer?.error
                ?? RecorderError.writerFailed("Failed to append a camera frame.")
        }
    }

    private func clearSession() {
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        writer = nil
        videoInput = nil
        videoAdaptor = nil
        terminalError = nil
    }
}

extension WebcamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        append(sampleBuffer)
    }
}
