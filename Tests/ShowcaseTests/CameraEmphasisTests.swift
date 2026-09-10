import Foundation
import Testing
@testable import Showcase

@Suite("Camera emphasis")
struct CameraEmphasisTests {
    @Test("Emphasis eases in, holds, and returns to normal inside its section")
    func envelope() {
        let effect = CameraEmphasis(startTime: 2, endTime: 5)
        #expect(effect.weight(at: 1) == 0)
        #expect(effect.weight(at: 2) == 0)
        #expect(abs(effect.weight(at: 2.2) - 0.5) < 0.00001)
        #expect(effect.weight(at: 3) == 1)
        #expect(abs(effect.weight(at: 4.8) - 0.5) < 0.00001)
        #expect(effect.weight(at: 5) == 0)
        #expect(effect.weight(at: 6) == 0)
    }

    @Test("Short emphasis keeps both transitions and preserves preferred timing when extended")
    func shortSection() {
        var effect = CameraEmphasis(startTime: 2, endTime: 2.1)
        #expect(effect.weight(at: 2) == 0)
        #expect(abs(effect.weight(at: 2.05) - 1) < 0.00001)
        #expect(effect.weight(at: 2.1) == 0)
        effect.endTime = 5
        #expect(abs(effect.weight(at: 2.2) - 0.5) < 0.00001)
        #expect(effect.transitionDuration == 0.4)
    }

    @Test("Touching camera effects transition directly, then restore normal size after the chain")
    func touchingEffects() {
        let project = project(effects: [
            CameraEmphasis(startTime: 1, endTime: 3, targetSize: 0.18),
            CameraEmphasis(startTime: 3, endTime: 5, targetSize: 0.45)
        ])
        #expect(project.emphasizedCameraSize(0.28, at: 1) == 0.28)
        #expect(project.emphasizedCameraSize(0.28, at: 2.9) == 0.18)
        #expect(project.emphasizedCameraSize(0.28, at: 3) == 0.18)
        #expect(abs(project.emphasizedCameraSize(0.28, at: 3.2) - 0.315) < 0.00001)
        #expect(project.emphasizedCameraSize(0.28, at: 4) == 0.45)
        #expect(abs(project.emphasizedCameraSize(0.28, at: 4.8) - 0.365) < 0.00001)
        #expect(project.emphasizedCameraSize(0.28, at: 5) == 0.28)
    }

    @Test("Equal touching sizes hold steady, and neighboring reductions never rise to normal at the join")
    func touchingReductions() {
        let project = project(effects: [
            CameraEmphasis(startTime: 1, endTime: 3, targetSize: 0.18),
            CameraEmphasis(startTime: 3, endTime: 5, targetSize: 0.18),
            CameraEmphasis(startTime: 5, endTime: 7, targetSize: 0.22)
        ])
        for time in stride(from: 2.7, through: 3.5, by: 0.01) {
            #expect(project.emphasizedCameraSize(0.28, at: time) == 0.18)
        }
        for time in stride(from: 4.7, through: 5.5, by: 0.01) {
            #expect((0.18...0.22).contains(project.emphasizedCameraSize(0.28, at: time)))
        }
    }

    @Test("Gaps between camera effects still return to normal")
    func separatedEffects() {
        let project = project(effects: [
            CameraEmphasis(startTime: 1, endTime: 3, targetSize: 0.18),
            CameraEmphasis(startTime: 3.1, endTime: 5, targetSize: 0.45)
        ])
        #expect(abs(project.emphasizedCameraSize(0.28, at: 2.8) - 0.23) < 0.00001)
        #expect(project.emphasizedCameraSize(0.28, at: 3.05) == 0.28)
        #expect(project.emphasizedCameraSize(0.28, at: 3.1) == 0.28)
    }

    @Test("Short adjacent camera effects stay continuous with unequal transition durations")
    func shortTouchingEffects() {
        let project = project(effects: [
            CameraEmphasis(startTime: 1, endTime: 1.1, targetSize: 0.18, transitionDuration: 1),
            CameraEmphasis(startTime: 1.1, endTime: 1.2, targetSize: 0.45, transitionDuration: 0.2)
        ])
        #expect(abs(project.emphasizedCameraSize(0.28, at: 1.1 - 0.000001) - 0.18) < 0.00001)
        #expect(project.emphasizedCameraSize(0.28, at: 1.1) == 0.18)
        #expect(abs(project.emphasizedCameraSize(0.28, at: 1.1 + 0.000001) - 0.18) < 0.00001)
        #expect(abs(project.emphasizedCameraSize(0.28, at: 1.15) - 0.45) < 0.00001)
        #expect(project.emphasizedCameraSize(0.28, at: 1.2) == 0.28)
    }

    private func project(effects: [CameraEmphasis]) -> RecordingProject {
        var project = RecordingProject(recording: RecordingMetadata(
            source: CaptureSourceDescriptor(kind: .display, sourceID: 1, title: "Test", applicationName: nil,
                frame: CodableRect(CGRect(x: 0, y: 0, width: 320, height: 180)), scaleFactor: 1),
            width: 320, height: 180, framesPerSecond: 30, duration: 10, includesSystemAudio: false,
            videoRelativePath: "screen.mov", eventsRelativePath: "events.json"))
        project.cameraEmphases = effects
        return project
    }

}
