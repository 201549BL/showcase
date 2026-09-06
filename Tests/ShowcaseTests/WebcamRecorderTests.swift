import Testing
@testable import Showcase

@Suite("Webcam recorder")
struct WebcamRecorderTests {
    @Test("commits capture-session configuration before starting")
    func commitsConfigurationBeforeStarting() {
        var events: [String] = []

        CaptureSessionLifecycle.configureAndStart(
            beginConfiguration: { events.append("begin") },
            configure: { events.append("configure") },
            commitConfiguration: { events.append("commit") },
            startRunning: { events.append("start") }
        )

        #expect(events == ["begin", "configure", "commit", "start"])
    }
}
