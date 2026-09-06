import CoreGraphics
import Foundation
import Testing
@testable import Showcase

@Suite("Recording setup")
@MainActor
struct RecordingSetupTests {
    @Test("First launch keeps the default recording settings")
    func initialRecordingPreferences() throws {
        let suiteName = "ShowcaseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(userDefaults: defaults)

        #expect(model.includesSystemAudio)
        #expect(!model.includesMicrophone)
        #expect(!model.includesCamera)
        #expect(model.selectedCameraID == nil)
        #expect(model.selectedMicrophoneID == nil)
    }

    @Test("Recording toggles and devices survive reopening, including turning them off again")
    func recordingPreferencesSurviveReopening() throws {
        let suiteName = "ShowcaseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(userDefaults: defaults)
        model.includesSystemAudio = false
        model.includesMicrophone = true
        model.includesCamera = true
        model.selectedCameraID = "external-camera"
        model.selectedMicrophoneID = "external-microphone"

        let reopened = AppModel(userDefaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(!reopened.includesSystemAudio)
        #expect(reopened.includesMicrophone)
        #expect(reopened.includesCamera)
        #expect(reopened.selectedCameraID == "external-camera")
        #expect(reopened.selectedMicrophoneID == "external-microphone")

        reopened.includesSystemAudio = true
        reopened.includesMicrophone = false
        reopened.includesCamera = false
        reopened.selectedCameraID = nil
        reopened.selectedMicrophoneID = nil

        let reset = AppModel(userDefaults: try #require(UserDefaults(suiteName: suiteName)))
        #expect(reset.includesSystemAudio)
        #expect(!reset.includesMicrophone)
        #expect(!reset.includesCamera)
        #expect(reset.selectedCameraID == nil)
        #expect(reset.selectedMicrophoneID == nil)
    }

    @Test("Countdown announces three beats before starting capture once")
    func countdownCompletes() async {
        let countdown = RecordingCountdown(sleep: { await Task.yield() })
        var ticks: [Int?] = []
        var starts = 0
        await withCheckedContinuation { continuation in
            countdown.start(tick: { ticks.append($0) }) {
                starts += 1
                continuation.resume()
            }
        }
        #expect(ticks == [3, 2, 1, nil])
        #expect(starts == 1)
    }

    @Test("Canceling a countdown prevents a delayed wake-up from starting capture")
    func cancellationPreventsCapture() async {
        let gate = CountdownGate()
        let countdown = RecordingCountdown(sleep: { await gate.sleep() })
        var starts = 0
        var ticks: [Int?] = []
        countdown.start(tick: { ticks.append($0) }) { starts += 1 }
        await gate.waitUntilSleeping()
        countdown.cancel()
        gate.release()
        // Queue a barrier on the same actor after the sleeping task resumes.
        await Task { @MainActor in }.value
        #expect(ticks == [3])
        #expect(starts == 0)
    }

    @Test("Restarting a countdown cannot complete the previous run")
    func restartInvalidatesOldCountdown() async {
        let gate = CountdownGate()
        let countdown = RecordingCountdown(sleep: { await gate.sleep() })
        var oldStarts = 0
        countdown.start(tick: { _ in }) { oldStarts += 1 }
        await gate.waitUntilSleeping()
        countdown.start(tick: { _ in }) { }
        gate.release()
        await Task { @MainActor in }.value
        countdown.cancel()
        gate.release()
        #expect(oldStarts == 0)
    }

    @Test("Capture outline converts recording coordinates across multiple displays")
    func sourceOutlineCoordinates() {
        #expect(RecordingWindowLayout.appKitRect(
            CGRect(x: 100, y: 200, width: 400, height: 300), desktopTop: 900
        ) == CGRect(x: 100, y: 400, width: 400, height: 300))
        #expect(RecordingWindowLayout.appKitRect(
            CGRect(x: -1_600, y: -900, width: 1_600, height: 900), desktopTop: 900
        ) == CGRect(x: -1_600, y: 900, width: 1_600, height: 900))
    }
}

@MainActor
private final class CountdownGate {
    private var sleeper: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func sleep() async {
        await withCheckedContinuation { continuation in
            sleeper = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSleeping() async {
        if sleeper != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        let continuation = sleeper
        sleeper = nil
        continuation?.resume()
    }
}
