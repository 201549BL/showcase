import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sources: [AvailableCaptureSource] = []
    @Published var selectedSourceID: String?
    @Published var includesSystemAudio = true
    @Published var includesMicrophone = false
    @Published private(set) var hasInputMonitoringPermission: Bool
    @Published private(set) var hasScreenRecordingPermission: Bool
    @Published private(set) var isLoadingSources = false
    @Published private(set) var isStartingOrStopping = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var activeProjectURL: URL?
    @Published private(set) var lastRecording: CompletedRecording?
    @Published private(set) var editor: EditorModel?
    @Published var presentedError: PresentedError?

    private let sourceService: CaptureSourceService
    private let coordinator: RecordingCoordinator
    private let privacyPermissions: any PrivacyPermissionClient
    private var elapsedTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

    init(
        sourceService: CaptureSourceService = CaptureSourceService(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        privacyPermissions: any PrivacyPermissionClient = SystemPrivacyPermissionClient()
    ) {
        self.sourceService = sourceService
        self.coordinator = coordinator
        self.privacyPermissions = privacyPermissions
        hasInputMonitoringPermission = privacyPermissions.hasInputMonitoringAccess()
        hasScreenRecordingPermission = privacyPermissions.hasScreenRecordingAccess()
        let startupProjectPath = ProcessInfo.processInfo.environment["SMOOTHSCREEN_PROJECT"]
            ?? CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".screenproject") })
        if let startupProjectPath {
            do {
                editor = try EditorModel(projectURL: URL(fileURLWithPath: startupProjectPath))
            } catch {
                presentedError = PresentedError(
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    var selectedSource: AvailableCaptureSource? {
        sources.first { $0.id == selectedSourceID }
    }

    func refreshSources() async {
        guard !isRecording else { return }
        refreshPermissionStatus()
        guard hasScreenRecordingPermission else {
            sources = []
            selectedSourceID = nil
            return
        }
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

    func refreshPermissionStatus() {
        hasInputMonitoringPermission = privacyPermissions.hasInputMonitoringAccess()
        hasScreenRecordingPermission = privacyPermissions.hasScreenRecordingAccess()
    }

    func requestInputMonitoringPermission() {
        _ = privacyPermissions.requestInputMonitoringAccess()
        refreshPermissionStatus()
        if !hasInputMonitoringPermission {
            privacyPermissions.openSettings(for: .inputMonitoring)
        }
    }

    func requestScreenRecordingPermission() async {
        _ = privacyPermissions.requestScreenRecordingAccess()
        refreshPermissionStatus()
        if hasScreenRecordingPermission {
            await refreshSources()
        } else {
            privacyPermissions.openSettings(for: .screenRecording)
        }
    }

    func startRecording() async {
        guard let selectedSource else { return }
        isStartingOrStopping = true
        defer { isStartingOrStopping = false }

        do {
            activeProjectURL = try await coordinator.start(
                source: selectedSource.descriptor,
                includesSystemAudio: includesSystemAudio,
                includesMicrophone: includesMicrophone
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
            editor = try EditorModel(projectURL: completed.projectURL)
        } catch {
            present(error)
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open SmoothScreen Project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            editor = try EditorModel(projectURL: url)
        } catch {
            present(error)
        }
    }

    func closeEditor() {
        editor?.player.pause()
        editor = nil
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
