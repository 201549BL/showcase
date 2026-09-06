import Testing
@testable import Showcase

@Suite("Permission onboarding")
@MainActor
struct PermissionTests {
    @Test("Screen Recording action requests access before opening Settings")
    func requestsScreenRecordingAccess() async {
        let permissions = FakePrivacyPermissionClient()
        let model = AppModel(privacyPermissions: permissions)

        await model.requestScreenRecordingPermission()

        #expect(permissions.screenRecordingRequestCount == 1)
        #expect(permissions.openedSettings == [.screenRecording])
    }

    @Test("Input Monitoring action requests access before opening Settings")
    func requestsInputMonitoringAccess() {
        let permissions = FakePrivacyPermissionClient()
        let model = AppModel(privacyPermissions: permissions)

        model.requestInputMonitoringPermission()

        #expect(permissions.inputMonitoringRequestCount == 1)
        #expect(permissions.openedSettings == [.inputMonitoring])
    }
}

private final class FakePrivacyPermissionClient: PrivacyPermissionClient {
    var screenRecordingGranted = false
    var inputMonitoringGranted = false
    var screenRecordingRequestCount = 0
    var inputMonitoringRequestCount = 0
    var openedSettings: [PrivacyPermission] = []

    func hasScreenRecordingAccess() -> Bool {
        screenRecordingGranted
    }

    func hasInputMonitoringAccess() -> Bool {
        inputMonitoringGranted
    }

    func requestScreenRecordingAccess() -> Bool {
        screenRecordingRequestCount += 1
        return screenRecordingGranted
    }

    func requestInputMonitoringAccess() -> Bool {
        inputMonitoringRequestCount += 1
        return inputMonitoringGranted
    }

    func openSettings(for permission: PrivacyPermission) {
        openedSettings.append(permission)
    }
}
