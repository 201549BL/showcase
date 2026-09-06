@preconcurrency import AVFoundation
import AppKit
import CoreImage

struct RecordingDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Owns setup-only device capture. All session work is serialized off the UI
/// thread; stop() completes before the recording sessions acquire the devices.
@MainActor
final class CaptureDevicePreview: ObservableObject {
    @Published private(set) var cameras: [RecordingDevice] = []
    @Published private(set) var microphones: [RecordingDevice] = []
    @Published private(set) var cameraImage: NSImage?
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var errorMessage: String?

    private let capture = DevicePreviewSession()
    private var generation = UUID()

    func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.map { RecordingDevice(id: $0.uniqueID, name: $0.localizedName) }
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { RecordingDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func update(cameraEnabled: Bool, cameraID: String?, microphoneEnabled: Bool, microphoneID: String?) async {
        let request = UUID()
        generation = request
        cameraImage = nil
        microphoneLevel = 0
        errorMessage = nil
        do {
            if cameraEnabled { try await Self.authorize(.video, name: "Camera") }
            if microphoneEnabled { try await Self.authorize(.audio, name: "Microphone") }
            guard !Task.isCancelled, generation == request else { return }
            try await capture.configure(
                cameraEnabled: cameraEnabled, cameraID: cameraID,
                microphoneEnabled: microphoneEnabled, microphoneID: microphoneID
            ) { [weak self] image, level in
                Task { @MainActor in
                    guard let self, self.generation == request else { return }
                    if let image { self.cameraImage = NSImage(cgImage: image, size: .zero) }
                    if let level { self.microphoneLevel = level }
                }
            }
        } catch {
            guard generation == request else { return }
            await capture.stop()
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        generation = UUID()
        await capture.stop()
        cameraImage = nil
        microphoneLevel = 0
    }

    static func authorize(_ mediaType: AVMediaType, name: String) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        let allowed: Bool
        if status == .notDetermined {
            allowed = await requestAccess(mediaType)
        } else {
            allowed = status == .authorized
        }
        if !allowed {
            throw PreviewError.unavailable("Enable \(name) access in System Settings → Privacy & Security.")
        }
    }

    private static func requestAccess(_ type: AVMediaType) async -> Bool {
        await AVCaptureDevice.requestAccess(for: type)
    }
}

private enum PreviewError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

// All mutable session state and delegate callbacks are confined to queue.
private final class DevicePreviewSession: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Showcase.SetupDevices")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var receive: ((CGImage?, Double?) -> Void)?
    private var lastVideoTime = -Double.infinity
    private var lastAudioTime = -Double.infinity

    func configure(
        cameraEnabled: Bool, cameraID: String?,
        microphoneEnabled: Bool, microphoneID: String?,
        receive: @escaping (CGImage?, Double?) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                clear()
                self.receive = receive
                do {
                    try CaptureSessionLifecycle.configureAndStart(
                        beginConfiguration: { session.beginConfiguration() },
                        configure: {
                            session.sessionPreset = .medium
                            if cameraEnabled {
                                try addInput(type: .video, id: cameraID)
                                let output = AVCaptureVideoDataOutput()
                                output.alwaysDiscardsLateVideoFrames = true
                                output.setSampleBufferDelegate(self, queue: queue)
                                guard session.canAddOutput(output) else { throw PreviewError.unavailable("Camera preview is unavailable.") }
                                session.addOutput(output)
                            }
                            if microphoneEnabled {
                                try addInput(type: .audio, id: microphoneID)
                                let output = AVCaptureAudioDataOutput()
                                output.setSampleBufferDelegate(self, queue: queue)
                                guard session.canAddOutput(output) else { throw PreviewError.unavailable("Microphone preview is unavailable.") }
                                session.addOutput(output)
                            }
                        },
                        commitConfiguration: { session.commitConfiguration() },
                        startRunning: { if cameraEnabled || microphoneEnabled { session.startRunning() } }
                    )
                    continuation.resume()
                } catch {
                    clear()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                clear()
                continuation.resume()
            }
        }
    }

    private func addInput(type: AVMediaType, id: String?) throws {
        let device: AVCaptureDevice?
        if let id { device = AVCaptureDevice(uniqueID: id) }
        else { device = AVCaptureDevice.default(for: type) }
        guard let device else { throw PreviewError.unavailable("No \(type == .video ? "camera" : "microphone") is connected.") }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw PreviewError.unavailable("The selected device is unavailable.") }
        session.addInput(input)
    }

    private func clear() {
        session.stopRunning()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        receive = nil
        lastVideoTime = -.infinity
        lastAudioTime = -.infinity
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMTimeGetSeconds(buffer.presentationTimeStamp)
        if output is AVCaptureVideoDataOutput, time - lastVideoTime >= 1.0 / 12,
           let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) {
            lastVideoTime = time
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            receive?(context.createCGImage(image, from: image.extent), nil)
        } else if output is AVCaptureAudioDataOutput, time - lastAudioTime >= 1.0 / 15 {
            lastAudioTime = time
            let decibels = connection.audioChannels.map(\.averagePowerLevel).max() ?? -60
            receive?(nil, min(1, max(0, (Double(decibels) + 60) / 60)))
        }
    }
}
