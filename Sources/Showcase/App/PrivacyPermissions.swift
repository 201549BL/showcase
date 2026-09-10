import AppKit
import ApplicationServices
import Foundation

enum PrivacyPermission: Equatable {
    case screenRecording
    case inputMonitoring

    fileprivate var settingsAnchor: String {
        switch self {
        case .screenRecording:
            return "Privacy_ScreenCapture"
        case .inputMonitoring:
            return "Privacy_ListenEvent"
        }
    }
}

protocol PrivacyPermissionClient {
    func hasScreenRecordingAccess() -> Bool
    func hasInputMonitoringAccess() -> Bool
    func requestScreenRecordingAccess() -> Bool
    func requestInputMonitoringAccess() -> Bool
    func openSettings(for permission: PrivacyPermission)
}

struct SystemPrivacyPermissionClient: PrivacyPermissionClient {
    func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func hasInputMonitoringAccess() -> Bool {
        CGPreflightListenEventAccess()
    }

    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    func openSettings(for permission: PrivacyPermission) {
        let currentSettingsURL = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(permission.settingsAnchor)"
        )
        let privacySettingsURL = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        )

        if let currentSettingsURL, NSWorkspace.shared.open(currentSettingsURL) {
            return
        }
        if let privacySettingsURL {
            NSWorkspace.shared.open(privacySettingsURL)
        }
    }
}
