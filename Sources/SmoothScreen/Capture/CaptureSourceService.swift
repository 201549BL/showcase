import CoreGraphics
import ScreenCaptureKit

struct AvailableCaptureSource: Identifiable, Hashable {
    let descriptor: CaptureSourceDescriptor

    var id: String { descriptor.id }
}

struct CaptureSourceService {
    enum SourceError: LocalizedError {
        case sourceNoLongerAvailable

        var errorDescription: String? {
            "The selected screen or window is no longer available. Refresh the source list and try again."
        }
    }

    func availableSources() async throws -> [AvailableCaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )

        let displays = content.displays.map { display in
            AvailableCaptureSource(
                descriptor: CaptureSourceDescriptor(
                    kind: .display,
                    sourceID: display.displayID,
                    title: displayName(for: display.displayID),
                    applicationName: nil,
                    frame: CodableRect(display.frame),
                    scaleFactor: scaleFactor(for: display)
                )
            )
        }

        let windows = content.windows
            .filter { window in
                guard window.frame.width >= 120, window.frame.height >= 80 else { return false }
                return window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            }
            .map { window in
                AvailableCaptureSource(
                    descriptor: CaptureSourceDescriptor(
                        kind: .window,
                        sourceID: window.windowID,
                        title: window.title?.isEmpty == false ? window.title! : "Untitled Window",
                        applicationName: window.owningApplication?.applicationName,
                        frame: CodableRect(window.frame),
                        scaleFactor: scaleFactor(for: window, displays: content.displays)
                    )
                )
            }
            .sorted { $0.descriptor.displayName.localizedStandardCompare($1.descriptor.displayName) == .orderedAscending }

        return displays + windows
    }

    func resolve(_ descriptor: CaptureSourceDescriptor) async throws -> ResolvedCaptureSource {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        switch descriptor.kind {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == descriptor.sourceID }) else {
                throw SourceError.sourceNoLongerAvailable
            }
            let excludedApplications = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            return .display(display, excludedApplications: excludedApplications)
        case .window:
            guard let window = content.windows.first(where: { $0.windowID == descriptor.sourceID }) else {
                throw SourceError.sourceNoLongerAvailable
            }
            return .window(window)
        }
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        if CGDisplayIsMain(displayID) != 0 {
            return "Main Display"
        }
        return "Display \(displayID)"
    }

    private func scaleFactor(for display: SCDisplay) -> Double {
        guard
            display.frame.width > 0,
            let mode = CGDisplayCopyDisplayMode(display.displayID)
        else { return 1 }

        return Double(mode.pixelWidth) / display.frame.width
    }

    private func scaleFactor(for window: SCWindow, displays: [SCDisplay]) -> Double {
        let intersectingDisplays = displays.filter { $0.frame.intersects(window.frame) }
        let display = intersectingDisplays.max { first, second in
            first.frame.intersection(window.frame).area < second.frame.intersection(window.frame).area
        }
        return display.map(scaleFactor(for:)) ?? 1
    }
}

enum ResolvedCaptureSource {
    case display(SCDisplay, excludedApplications: [SCRunningApplication])
    case window(SCWindow)

    var contentFilter: SCContentFilter {
        switch self {
        case .display(let display, let excludedApplications):
            return SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }
}

private extension CGRect {
    var area: Double {
        guard !isNull, !isInfinite else { return 0 }
        return width * height
    }
}
