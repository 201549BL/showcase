import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sources: [AvailableCaptureSource] = []
    @Published var selectedSourceID: String?
    @Published var includesSystemAudio = true
    @Published private(set) var isLoadingSources = false
    @Published private(set) var isStartingOrStopping = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var activeProjectURL: URL?
    @Published private(set) var lastRecording: CompletedRecording?
    @Published var presentedError: PresentedError?

    private let sourceService: CaptureSourceService
    private let coordinator: RecordingCoordinator
    private var elapsedTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

    init(
        sourceService: CaptureSourceService = CaptureSourceService(),
        coordinator: RecordingCoordinator = RecordingCoordinator()
    ) {
        self.sourceService = sourceService
        self.coordinator = coordinator
    }

    var selectedSource: AvailableCaptureSource? {
        sources.first { $0.id == selectedSourceID }
    }

    func refreshSources() async {
        guard !isRecording else { return }
        isLoadingSources = true
        defer { isLoadingSources = false }

        do {
            sources = try await sourceService.availableSources()
            if !sources.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = sources.first?.id
            }
        } catch {
            present(error)
        }
    }

    func startRecording() async {
        guard let selectedSource else { return }
        isStartingOrStopping = true
        defer { isStartingOrStopping = false }

        do {
            activeProjectURL = try await coordinator.start(
                source: selectedSource.descriptor,
                includesSystemAudio: includesSystemAudio
            )
            isRecording = true
            elapsedTime = 0
            recordingStartedAt = Date()
            startElapsedTimer()
        } catch {
            present(error)
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        isStartingOrStopping = true
        defer { isStartingOrStopping = false }

        do {
            let completed = try await coordinator.stop()
            elapsedTask?.cancel()
            elapsedTask = nil
            isRecording = false
            elapsedTime = completed.duration
            activeProjectURL = nil
            lastRecording = completed
        } catch {
            present(error)
        }
    }

    func revealLastRecording() {
        guard let url = lastRecording?.projectURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard
                    let self,
                    let recordingStartedAt = self.recordingStartedAt
                else { continue }
                self.elapsedTime = Date().timeIntervalSince(recordingStartedAt)
            }
        }
    }

    private func present(_ error: Error) {
        presentedError = PresentedError(
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
    }
}

struct PresentedError: Identifiable {
    let id = UUID()
    let message: String
}
