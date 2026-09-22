import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Showcase

@Suite("Frame compositor")
struct FrameCompositorTests {
    @Test("Composites every cursor theme and shape", arguments: RecordedInputEvent.CursorStyle.allCases, CursorSettings.Theme.allCases)
    func compositesVisibleCursorPixels(style: RecordedInputEvent.CursorStyle, theme: CursorSettings.Theme) throws {
        var project = fixtureProject()
        project.cursor.theme = theme
        project.canvas.aspectRatio = .source
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.hideAfter = 10

        var cursorEvent = RecordedInputEvent(
            timestamp: 0,
            type: .mouseMoved,
            position: CodablePoint(CGPoint(x: 160, y: 90)),
            buttonNumber: 0,
            scrollDeltaX: nil,
            scrollDeltaY: nil,
            keyCode: nil,
            flags: 0
        )
        cursorEvent.cursorStyle = style
        let source = CIImage(
            color: CIColor(red: 0.08, green: 0.42, blue: 0.73, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)

        let withCursor = FrameCompositor(
            project: project,
            events: [cursorEvent],
            quality: .hd
        ).render(sourceImage: source, at: time)
        let withoutCursor = FrameCompositor(
            project: project,
            events: [],
            quality: .hd
        ).render(sourceImage: source, at: time)

        let cursorPixels = rgbaPixels(in: withCursor)
        let baselinePixels = rgbaPixels(in: withoutCursor)
        let changedPixelCount = stride(from: 0, to: cursorPixels.count, by: 4).reduce(into: 0) {
            if cursorPixels[$1..<$1 + 4] != baselinePixels[$1..<$1 + 4] {
                $0 += 1
            }
        }

        #expect(changedPixelCount >= 20)
    }

    @Test("Cursor colors change fill and outline without tinting the recording", arguments: CursorSettings.Theme.allCases)
    func customCursorColors(theme: CursorSettings.Theme) throws {
        var project = fixtureProject()
        project.cursor.theme = theme
        project.canvas.aspectRatio = .landscape
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.hideAfter = 10
        project.cursor.showsClickAnimation = false
        project.cursor.scale = 2.5
        project.cursor.fillHex = "#FF0000"
        project.cursor.outlineHex = "#00FF00"
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let rendered = FrameCompositor(project: project,
                                       events: [cursorEvent(x: 160, y: 90)], quality: .hd)
            .render(sourceImage: source, at: CMTime(seconds: 0.5, preferredTimescale: 600))
        let pixels = rgbaPixels(in: rendered)
        let indices = stride(from: 0, to: pixels.count, by: 4)
        #expect(indices.contains { pixels[$0] > 230 && pixels[$0 + 1] < 20 && pixels[$0 + 2] < 20 })
        #expect(indices.contains { pixels[$0] < 70 && pixels[$0 + 1] > 230 && pixels[$0 + 2] < 70 })
        #expect(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 255)

        if theme == .capitaine {
            project.cursor.outlineHex = "#FF00FF"
            var copyEvent = cursorEvent(x: 160, y: 90)
            copyEvent.cursorStyle = .dragCopy
            let copy = FrameCompositor(project: project, events: [copyEvent], quality: .hd)
                .render(sourceImage: source, at: CMTime(seconds: 0.5, preferredTimescale: 600))
            let copyPixels = rgbaPixels(in: copy)
            #expect(stride(from: 0, to: copyPixels.count, by: 4).contains {
                copyPixels[$0] < 80 && copyPixels[$0 + 1] > 180 && copyPixels[$0 + 2] < 80
            })
        }
    }

    @Test("Legacy cursor settings keep Ice colors and custom colors round-trip")
    func cursorColorPersistence() throws {
        let legacy = Data(#"{"scale":1.4,"smoothing":0.65,"hideAfter":2,"showsClickAnimation":true}"#.utf8)
        var settings = try JSONDecoder().decode(CursorSettings.self, from: legacy)
        #expect(settings.resolvedTheme == .bibata)
        #expect(settings.resolvedFillHex == "#FFFFFF")
        #expect(settings.resolvedOutlineHex == "#000000")
        settings.theme = .capitaine
        settings.fillHex = "#FF8300"
        settings.outlineHex = "#FFFFFF"
        let restored = try JSONDecoder().decode(CursorSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }

    @Test("Renders the cursor appearance recorded for the hovered action")
    func rendersRecordedCursorAppearance() {
        var project = fixtureProject()
        project.canvas.aspectRatio = .source
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.hideAfter = 10
        project.cursor.showsClickAnimation = false

        let source = CIImage(
            color: CIColor(red: 0.08, green: 0.42, blue: 0.73, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        var arrowEvent = cursorEvent(x: 160, y: 90)
        arrowEvent.cursorStyle = .arrow
        var handEvent = cursorEvent(x: 160, y: 90)
        handEvent.cursorStyle = .pointingHand

        let arrow = FrameCompositor(
            project: project,
            events: [arrowEvent],
            quality: .hd
        ).render(sourceImage: source, at: time)
        let hand = FrameCompositor(
            project: project,
            events: [handEvent],
            quality: .hd
        ).render(sourceImage: source, at: time)
        let baseline = FrameCompositor(
            project: project,
            events: [],
            quality: .hd
        ).render(sourceImage: source, at: time)

        let arrowPixels = rgbaPixels(in: arrow)
        let handPixels = rgbaPixels(in: hand)
        let baselinePixels = rgbaPixels(in: baseline)
        let handSize = changedPixelSize(
            between: handPixels,
            and: baselinePixels,
            width: Int(hand.extent.width)
        )

        #expect(arrowPixels != handPixels)
        #expect(max(handSize.width, handSize.height) >= 10)
    }

    @Test("Motion blur follows moving cursor poses and leaves still frames sharp")
    func motionBlurOnlyAffectsMovement() {
        var project = fixtureProject()
        project.canvas.aspectRatio = .source
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.smoothing = 0
        project.cursor.hideAfter = 10
        project.cursor.showsClickAnimation = false
        let source = CIImage(
            color: CIColor(red: 0.08, green: 0.42, blue: 0.73, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let movingEvents = [
            cursorEvent(timestamp: 0.48, x: 100, y: 90),
            cursorEvent(timestamp: 0.52, x: 220, y: 90)
        ]
        let stationaryEvents = [
            cursorEvent(timestamp: 0.48, x: 160, y: 90),
            cursorEvent(timestamp: 0.52, x: 160, y: 90)
        ]

        project.motionBlur = MotionBlurSettings(amount: 1)
        let blurredMovement = FrameCompositor(
            project: project,
            events: movingEvents,
            quality: .hd
        ).render(sourceImage: source, at: time)
        let blurredStill = FrameCompositor(
            project: project,
            events: stationaryEvents,
            quality: .hd
        ).render(sourceImage: source, at: time)

        project.motionBlur = .disabled
        let sharpMovement = FrameCompositor(
            project: project,
            events: movingEvents,
            quality: .hd
        ).render(sourceImage: source, at: time)
        let sharpStill = FrameCompositor(
            project: project,
            events: stationaryEvents,
            quality: .hd
        ).render(sourceImage: source, at: time)

        #expect(rgbaPixels(in: blurredMovement) != rgbaPixels(in: sharpMovement))
        #expect(rgbaPixels(in: blurredStill) == rgbaPixels(in: sharpStill))
    }

    @Test("Motion blur does not dim screen pixels away from the moving cursor")
    func motionBlurPreservesScreenBrightness() {
        var project = fixtureProject()
        project.canvas.aspectRatio = .source
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.smoothing = 0
        project.cursor.hideAfter = 10
        project.cursor.showsClickAnimation = false
        let source = CIImage(
            color: CIColor(red: 0.82, green: 0.86, blue: 0.91, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let movingEvents = [
            cursorEvent(timestamp: 0.48, x: 100, y: 90),
            cursorEvent(timestamp: 0.52, x: 220, y: 90)
        ]

        project.motionBlur = MotionBlurSettings(amount: 0.5)
        let blurred = FrameCompositor(
            project: project,
            events: movingEvents,
            quality: .hd
        ).render(sourceImage: source, at: time)

        project.motionBlur = .disabled
        let sharp = FrameCompositor(
            project: project,
            events: movingEvents,
            quality: .hd
        ).render(sourceImage: source, at: time)

        let blurredPixels = rgbaPixels(in: blurred)
        let sharpPixels = rgbaPixels(in: sharp)
        let sample = (40 * Int(blurred.extent.width) + 40) * 4

        #expect(
            Array(blurredPixels[sample..<(sample + 4)])
                == Array(sharpPixels[sample..<(sample + 4)])
        )
    }

    @Test("Face camera is composited independently and can be hidden")
    func compositesFaceCameraOverlay() {
        var project = fixtureProject()
        project.canvas.aspectRatio = .source
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.recording.cameraVideoRelativePath = "media/camera.mov"
        project.cameraOverlay = .default
        let screen = CIImage(
            color: CIColor(red: 0.08, green: 0.42, blue: 0.73, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let camera = CIImage(
            color: CIColor(red: 0.85, green: 0.12, blue: 0.18, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let provider = StaticCameraFrameProvider(image: camera)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)

        let visible = FrameCompositor(
            project: project,
            events: [],
            quality: .hd,
            cameraFrameProvider: provider
        ).render(sourceImage: screen, at: time)
        let withoutProvider = FrameCompositor(
            project: project,
            events: [],
            quality: .hd
        ).render(sourceImage: screen, at: time)

        project.cameraOverlay?.isVisible = false
        let hidden = FrameCompositor(
            project: project,
            events: [],
            quality: .hd,
            cameraFrameProvider: provider
        ).render(sourceImage: screen, at: time)

        #expect(rgbaPixels(in: visible) != rgbaPixels(in: withoutProvider))
        #expect(rgbaPixels(in: hidden) == rgbaPixels(in: withoutProvider))
    }

    @Test("Automatic camera shrinks for content, restores for talking, and respects removal and manual overrides")
    func automaticCameraShrinkRendering() {
        var project = fixtureProject()
        project.recording.duration = 5
        project.recording.cameraVideoRelativePath = "media/camera.mov"
        project.cameraOverlay = .default
        project.zoomSegments = [ZoomSegment(id: UUID(), startTime: 1, focusTime: 1.5, endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 160, y: 90)), scale: 1.95, source: .automatic)]
        let camera = StaticCameraFrameProvider(image: CIImage(color: .green)
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)))
        let screen = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        func area(_ compositor: FrameCompositor, at seconds: Double) -> Int {
            let pixels = rgbaPixels(in: compositor.render(sourceImage: screen,
                at: CMTime(seconds: seconds, preferredTimescale: 600)))
            return stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] < 80 && pixels[$0 + 1] > 200 && pixels[$0 + 2] < 80
            }.count
        }
        let automatic = FrameCompositor(project: project, events: [], quality: .hd, cameraFrameProvider: camera)
        var equivalentManualProject = project
        equivalentManualProject.synchronizeCameraEffects()
        equivalentManualProject.cameraEmphases?[0].source = .manual
        let equivalentManual = FrameCompositor(project: equivalentManualProject, events: [], quality: .hd,
                                               cameraFrameProvider: camera)
        // Provenance must never change the envelope or apply a second, hidden size reduction.
        for seconds in [1.1, 1.3, 2.5, 3.8] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            #expect(rgbaPixels(in: automatic.render(sourceImage: screen, at: time))
                == rgbaPixels(in: equivalentManual.render(sourceImage: screen, at: time)))
        }
        let talking = area(automatic, at: 0.5)
        let focused = area(automatic, at: 2.5)
        #expect(talking > 0)
        let retainedArea = Double(focused) / Double(talking)
        #expect(retainedArea > 0.68 && retainedArea < 0.78)
        #expect(area(automatic, at: 4.5) == talking)
        project.suppressedAutomaticCameraZoomIDs = [project.zoomSegments[0].id]
        let removed = FrameCompositor(project: project, events: [], quality: .hd, cameraFrameProvider: camera)
        #expect(area(removed, at: 2.5) == talking)
        project.suppressedAutomaticCameraZoomIDs = nil
        project.cameraEmphases = [CameraEmphasis(startTime: 2, endTime: 3, targetSize: 0.45)]
        let manual = FrameCompositor(project: project, events: [], quality: .hd, cameraFrameProvider: camera)
        #expect(area(manual, at: 2.5) > talking)
        #expect(area(manual, at: 3.5) < talking)
    }

    @Test("Camera emphasis changes rendered bubble size and returns to the original preview and export frames")
    func rendersCameraEmphasis() throws {
        var project = fixtureProject()
        project.recording.duration = 5
        project.recording.cameraVideoRelativePath = "media/camera.mov"
        project.cameraOverlay = .default
        let legacy = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project))
        #expect(legacy.cameraEmphases == nil)
        #expect(legacy.emphasizedCameraSize(0.22, at: 2) == 0.22)
        let camera = StaticCameraFrameProvider(image: CIImage(color: .red)
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)))
        let screen = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let base = project
        project.cameraEmphases = [CameraEmphasis(startTime: 1, endTime: 4, targetSize: 0.5)]
        let roundTrip = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project))
        #expect(roundTrip == project)
        for cap: Double? in [nil, 640] {
            let baseline = FrameCompositor(project: base, events: [], quality: .hd,
                maximumCanvasDimension: cap, cameraFrameProvider: camera)
            let emphasized = FrameCompositor(project: roundTrip, events: [], quality: .hd,
                maximumCanvasDimension: cap, cameraFrameProvider: camera)
            for seconds in [0.0, 1, 4, 4.5] {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                #expect(rgbaPixels(in: emphasized.render(sourceImage: screen, at: time))
                    == rgbaPixels(in: baseline.render(sourceImage: screen, at: time)))
            }
            let middle = CMTime(seconds: 2, preferredTimescale: 600)
            #expect(rgbaPixels(in: emphasized.render(sourceImage: screen, at: middle))
                != rgbaPixels(in: baseline.render(sourceImage: screen, at: middle)))
        }
        project.cameraSegments = []
        let hidden = FrameCompositor(project: project, events: [], quality: .hd, cameraFrameProvider: camera)
        let noCamera = FrameCompositor(project: project, events: [], quality: .hd)
        let middle = CMTime(seconds: 2, preferredTimescale: 600)
        #expect(rgbaPixels(in: hidden.render(sourceImage: screen, at: middle))
            == rgbaPixels(in: noCamera.render(sourceImage: screen, at: middle)))
    }

    @Test("Camera mirroring preserves legacy appearance and can be changed per section")
    func cameraMirroring() throws {
        var project = fixtureProject()
        project.recording.cameraVideoRelativePath = "media/camera.mov"
        project.cameraOverlay = .default
        let legacyData = try JSONEncoder().encode(project)
        let legacy = try JSONDecoder().decode(RecordingProject.self, from: legacyData)
        #expect(legacy.resolvedCameraOverlay.isMirrored == nil)
        #expect(legacy.resolvedCameraOverlay.resolvedIsMirrored)
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
        let camera = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 480))
            .composited(over: CIImage(color: .blue).cropped(to: bounds))
        let screen = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let time = CMTime(seconds: 0.25, preferredTimescale: 600)
        func pixels(_ project: RecordingProject, camera: CIImage, time: CMTime) -> [UInt8] {
            rgbaPixels(in: FrameCompositor(project: project, events: [], quality: .hd,
                cameraFrameProvider: StaticCameraFrameProvider(image: camera)).render(sourceImage: screen, at: time))
        }
        let mirrored = pixels(project, camera: camera, time: time)
        project.cameraOverlay?.isMirrored = true
        #expect(pixels(project, camera: camera, time: time) == mirrored)
        project.cameraOverlay?.isMirrored = false
        let original = pixels(project, camera: camera, time: time)
        #expect(original != mirrored)
        let flippedCamera = camera.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 640, ty: 0))
        #expect(pixels(project, camera: flippedCamera, time: time) == mirrored)
        var sectionSettings = project.resolvedCameraOverlay
        sectionSettings.isMirrored = true
        project.cameraSegments = [CameraSegment(startTime: 0, endTime: 0.5),
                                  CameraSegment(startTime: 0.5, endTime: 1, settings: sectionSettings)]
        let restored = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project))
        #expect(pixels(restored, camera: camera, time: time) == original)
        #expect(pixels(restored, camera: camera, time: CMTime(seconds: 0.75, preferredTimescale: 600)) == mirrored)
    }

    @Test("Camera sections render only inside their intervals and use their own position and size")
    func cameraSectionRendering() throws {
        var project = fixtureProject()
        project.recording.duration = 10
        project.recording.cameraVideoRelativePath = "media/camera.mov"
        project.cameraOverlay = .default
        let legacy = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project))
        #expect(legacy.cameraSegments == nil)
        #expect(legacy.cameraSettings(at: 0) == .default)
        #expect(legacy.cameraSettings(at: 9.9) == .default)
        var topLeft = CameraOverlaySettings.default
        topLeft.corner = .topLeft
        topLeft.size = 0.4
        project.cameraSegments = [
            CameraSegment(startTime: 1, endTime: 3),
            CameraSegment(startTime: 5, endTime: 8, settings: topLeft)
        ]
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project))
        #expect(decoded == project)
        let screen = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let provider = StaticCameraFrameProvider(image: CIImage(color: .red)
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)))
        let compositor = FrameCompositor(project: project, events: [], quality: .hd, cameraFrameProvider: provider)
        let baseline = FrameCompositor(project: project, events: [], quality: .hd)
        for second in [0.0, 0.999, 3, 4, 8, 9.9] {
            let time = CMTime(seconds: second, preferredTimescale: 600)
            #expect(rgbaPixels(in: compositor.render(sourceImage: screen, at: time))
                == rgbaPixels(in: baseline.render(sourceImage: screen, at: time)))
        }
        let first = rgbaPixels(in: compositor.render(sourceImage: screen, at: CMTime(seconds: 1, preferredTimescale: 600)))
        let second = rgbaPixels(in: compositor.render(sourceImage: screen, at: CMTime(seconds: 5, preferredTimescale: 600)))
        #expect(first != second)
        #expect(provider.lastTime?.seconds == 5) // Section boundaries never shift the source camera clock.
        var reference = project
        reference.cameraSegments = nil
        reference.cameraOverlay = topLeft
        let topLeftCompositor = FrameCompositor(project: reference, events: [], quality: .hd, cameraFrameProvider: provider)
        #expect(second == rgbaPixels(in: topLeftCompositor.render(sourceImage: screen, at: CMTime(seconds: 5, preferredTimescale: 600))))
        project.cameraOverlay?.isVisible = false
        #expect(project.cameraSettings(at: 5) == nil)
        project.cameraOverlay?.isVisible = true
        project.cameraSegments?[1].settings?.isVisible = false
        #expect(project.cameraSettings(at: 5) == nil)
        project.cameraSegments = []
        #expect(project.cameraSettings(at: 2) == nil)
    }

    @Test("Vertical framing keeps the full cursor bitmap inside the viewport")
    func verticalFramingKeepsFullCursorVisible() {
        var project = fixtureProject()
        project.canvas.aspectRatio = .vertical
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.hideAfter = 10
        project.cursor.smoothing = 0
        project.cursor.showsClickAnimation = false
        project.zoomSegments = [
            ZoomSegment(
                id: UUID(),
                startTime: 0,
                focusTime: 0.4,
                endTime: 2,
                focusPoint: CodablePoint(CGPoint(x: 160, y: 90)),
                scale: 1.75,
                source: .automatic
            )
        ]
        let cursorPosition = CGPoint(x: 160, y: 145)
        let compositor = FrameCompositor(
            project: project,
            events: [
                cursorEvent(timestamp: 0.99, x: 160, y: 90),
                cursorEvent(timestamp: 1, x: cursorPosition.x, y: cursorPosition.y)
            ],
            quality: .hd
        )
        let camera = compositor.cameraState(at: 1)
        let geometry = CanvasGeometry(project: project, quality: .hd)
        let cursorCanvasScale = project.cursor.scale * geometry.canvasSize.height / 1_080
        let cursorBottomFraction = (48 - 17.0 * 48 / 256) * cursorCanvasScale
            / (geometry.screenRect.height / 2)
        let visibleHalfHeight = Double(project.recording.height) / (2 * camera.scale)
        let allowedDownwardDelta = visibleHalfHeight * (1 - cursorBottomFraction)
        #expect(cursorPosition.y - camera.focusPoint.y <= allowedDownwardDelta + 0.001)
    }

    @Test("Large vertical cursor uses a one-sided safe viewport region")
    func largeVerticalCursorUsesAsymmetricSafeRegion() {
        var project = fixtureProject()
        project.canvas.aspectRatio = .vertical
        project.canvas.padding = 160
        project.cursor.scale = 2
        project.cursor.smoothing = 0
        project.cursor.hideAfter = 10
        project.zoomSegments = [
            ZoomSegment(
                id: UUID(),
                startTime: 0,
                focusTime: 0.4,
                endTime: 2,
                focusPoint: CodablePoint(CGPoint(x: 160, y: 90)),
                scale: 1.75,
                source: .automatic
            )
        ]
        let cursorPosition = CGPoint(x: 160, y: 70)
        let compositor = FrameCompositor(
            project: project,
            events: [cursorEvent(timestamp: 1, x: cursorPosition.x, y: cursorPosition.y)],
            quality: .hd
        )
        let camera = compositor.cameraState(at: 1)
        let geometry = CanvasGeometry(project: project, quality: .hd)
        let cursorCanvasScale = project.cursor.scale * geometry.canvasSize.height / 1_080
        let topInset = 24 * cursorCanvasScale / (geometry.screenRect.height / 2)
        let bottomInset = (48 - 17.0 * 48 / 256) * cursorCanvasScale / (geometry.screenRect.height / 2)
        let visibleHalfHeight = Double(project.recording.height) / (2 * camera.scale)
        let allowedRange: ClosedRange<Double> = (
            -visibleHalfHeight * (1 - topInset)
        )...(
            visibleHalfHeight * (1 - bottomInset)
        )
        let cursorDelta = Double(cursorPosition.y - camera.focusPoint.y)

        #expect(allowedRange.upperBound < 0)
        #expect(cursorDelta >= allowedRange.lowerBound - 0.001)
        #expect(cursorDelta <= allowedRange.upperBound + 0.001)
    }

    @Test("AVPlayer preview preserves off-center cursor pixels at reduced preview size")
    @MainActor
    func playerPreviewPreservesCursorPixels() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let videoURL = temporaryRoot.appendingPathComponent("static.mov")
        try await createStaticFixtureVideo(at: videoURL, width: 320, height: 180)

        var project = RecordingProject(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            recording: RecordingMetadata(
                source: CaptureSourceDescriptor(
                    kind: .display,
                    sourceID: 1,
                    title: "Fixture",
                    applicationName: nil,
                    frame: CodableRect(CGRect(x: 0, y: 0, width: 320, height: 180)),
                    scaleFactor: 1
                ),
                width: 320,
                height: 180,
                framesPerSecond: 30,
                duration: 1,
                includesSystemAudio: false,
                includesMicrophone: false,
                videoRelativePath: "static.mov",
                eventsRelativePath: "events.json"
            )
        )
        project.canvas.aspectRatio = .landscape
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowRadius = 0
        project.cursor.hideAfter = 30
        project.cursor.showsClickAnimation = false
        let cursorEvent = RecordedInputEvent(
            timestamp: 0,
            type: .mouseMoved,
            position: CodablePoint(CGPoint(x: 240, y: 90)),
            buttonNumber: 0,
            scrollDeltaX: nil,
            scrollDeltaY: nil,
            keyCode: nil,
            flags: 0
        )
        let asset = AVURLAsset(url: videoURL)

        let visibleComposition = VideoCompositionBuilder().build(
            asset: asset,
            project: project,
            events: [cursorEvent],
            quality: .hd,
            purpose: .preview
        ).composition
        let hiddenComposition = VideoCompositionBuilder().build(
            asset: asset,
            project: project,
            events: [],
            quality: .hd,
            purpose: .preview
        ).composition
        #expect(visibleComposition.renderScale == 1)
        #expect(visibleComposition.renderSize == CGSize(width: 1_280, height: 720))

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let visiblePixels = try await playerPixels(
            asset: asset,
            composition: visibleComposition,
            at: time
        )
        let hiddenPixels = try await playerPixels(
            asset: asset,
            composition: hiddenComposition,
            at: time
        )
        #expect(visiblePixels.count == hiddenPixels.count)
        let changedPixelCount = stride(from: 0, to: visiblePixels.count, by: 4).reduce(into: 0) {
            if visiblePixels[$1..<$1 + 4] != hiddenPixels[$1..<$1 + 4] {
                $0 += 1
            }
        }

        #expect(changedPixelCount >= 100)
    }

    @Test("Preview canvas cap does not reduce full-quality exports")
    @MainActor
    func previewCanvasCapDoesNotLeakIntoExports() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let videoURL = temporaryRoot.appendingPathComponent("static.mov")
        try await createStaticFixtureVideo(at: videoURL, width: 320, height: 180)

        var project = fixtureProject()
        project.canvas.aspectRatio = .landscape
        let asset = AVURLAsset(url: videoURL)
        let cases: [(ExportQuality, CGSize)] = [
            (.hd, CGSize(width: 1_920, height: 1_080)),
            (.ultraHD, CGSize(width: 3_840, height: 2_160))
        ]

        for (quality, expectedExportSize) in cases {
            let preview = VideoCompositionBuilder().build(
                asset: asset,
                project: project,
                events: [],
                quality: quality,
                purpose: .preview
            )
            let export = VideoCompositionBuilder().build(
                asset: asset,
                project: project,
                events: [],
                quality: quality
            )

            #expect(preview.composition.renderSize == CGSize(width: 1_280, height: 720))
            #expect(preview.composition.renderScale == 1)
            #expect(export.composition.renderSize == expectedExportSize)
            #expect(export.compositor.renderSize == expectedExportSize)
            #expect(export.composition.renderScale == 1)
        }
    }

    @Test("Zoom moves the entire recording card without reshaping its frame in preview and export")
    func zoomCardRendering() {
        var project = fixtureProject()
        project.recording.duration = 7
        project.canvas.padding = 100
        project.canvas.cornerRadius = 32
        project.canvas.shadowRadius = 24
        project.canvas.backgroundStartHex = "FF0000"
        project.canvas.backgroundEndHex = "FF0000"
        project.motionBlur = .disabled
        project.zoomSegments = [ZoomSegment(id: UUID(), startTime: 1, focusTime: 1.5, endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 240, y: 110)), scale: 1.95, source: .manual)]
        let source = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        for aspect in [CanvasSettings.AspectRatio.landscape, .square, .vertical] {
            project.canvas.aspectRatio = aspect
            for cap: Double? in [nil, 640] {
                let compositor = FrameCompositor(project: project, events: [], quality: .hd, maximumCanvasDimension: cap)
                let geometry = CanvasGeometry(project: project, quality: .hd, maximumCanvasDimension: cap)
                let canvas = CGRect(origin: .zero, size: compositor.renderSize)
                func frame(_ time: Double) -> CIImage {
                    compositor.render(sourceImage: source, at: CMTime(seconds: time, preferredTimescale: 600))
                }
                let overview = frame(0)
                for time in [1.15, 2.0, 3.9] {
                    let camera = compositor.cameraState(at: time)
                    let focusInCard = CGPoint(
                        x: geometry.screenRect.minX + camera.focusPoint.x / 320 * geometry.screenRect.width,
                        y: geometry.screenRect.minY + (1 - camera.focusPoint.y / 180) * geometry.screenRect.height
                    )
                    // A physical camera move is equivalent to scaling the complete overview
                    // about its focus, with the unchanged background behind it.
                    let expected = overview.transformed(by: CGAffineTransform(
                        a: camera.scale, b: 0, c: 0, d: camera.scale,
                        tx: canvas.midX - focusInCard.x * camera.scale,
                        ty: canvas.midY - focusInCard.y * camera.scale
                    )).composited(over: CIImage(color: .red)).cropped(to: canvas)
                    let actualPixels = rgbaPixels(in: frame(time))
                    let expectedPixels = rgbaPixels(in: expected)
                    let matching = zip(actualPixels, expectedPixels).filter { abs(Int($0) - Int($1)) <= 2 }.count
                    #expect(Double(matching) / Double(actualPixels.count) > 0.995)
                }
                #expect(rgbaPixels(in: frame(6)) == rgbaPixels(in: overview))
                let focused = rgbaPixels(in: frame(2))
                _ = frame(0)
                #expect(rgbaPixels(in: frame(2)) == focused)
            }
        }
    }

    @Test("Moving a portrait recording card keeps an off-center automatic cursor visible")
    func zoomCardCursorVisibility() {
        var project = fixtureProject()
        project.recording.duration = 5
        project.canvas.aspectRatio = .vertical
        project.canvas.padding = 100
        project.cursor.smoothing = 0
        project.cursor.hideAfter = 10
        project.cursor.showsClickAnimation = false
        project.motionBlur = .disabled
        project.zoomSegments = [ZoomSegment(id: UUID(), startTime: 1, focusTime: 1.5, endTime: 4,
            focusPoint: CodablePoint(CGPoint(x: 160, y: 90)), scale: 1.95, source: .automatic)]
        let source = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        func cursorArea(x: Double, y: Double) -> Int {
            let events = [cursorEvent(timestamp: 1, x: x, y: y)]
            let compositor = FrameCompositor(project: project, events: events, quality: .hd, maximumCanvasDimension: 640)
            var hiddenCursor = project
            hiddenCursor.cursor.scale = 0
            let baseline = FrameCompositor(project: hiddenCursor, events: events, quality: .hd, maximumCanvasDimension: 640)
            let time = CMTime(seconds: 2, preferredTimescale: 600)
            let pixels = rgbaPixels(in: compositor.render(sourceImage: source, at: time))
            let baselinePixels = rgbaPixels(in: baseline.render(sourceImage: source, at: time))
            // Count cursor pixels on the blue recording only, excluding the moving card edges.
            var count = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let isRecording = baselinePixels[index] < 5
                    && baselinePixels[index + 1] < 5 && baselinePixels[index + 2] > 250
                let isCursor = pixels[index] > 30
                    || pixels[index + 1] > 30 || pixels[index + 2] < 225
                if isRecording && isCursor { count += 1 }
            }
            return count
        }
        let centered = cursorArea(x: 160, y: 90)
        #expect(centered > 0)
        for (x, y) in [(285.0, 160.0), (35.0, 20.0)] {
            #expect(Double(cursorArea(x: x, y: y)) >= Double(centered) * 0.9)
        }
    }

    @Test("Image backgrounds fill the canvas with a centered crop in both preview and export")
    func imageBackgroundRendering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("wide.png")
        try writeBackgroundFixture(to: original)
        var project = fixtureProject()
        project.canvas.backgroundImage = try BackgroundImages.importImage(at: original, into: root)
        let source = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        for aspect in [CanvasSettings.AspectRatio.landscape, .square, .vertical] {
            project.canvas.aspectRatio = aspect
            for purpose in [VideoCompositionBuilder.Purpose.preview, .export] {
                let built = VideoCompositionBuilder().build(asset: AVMutableComposition(), project: project,
                    events: [], quality: .hd, purpose: purpose, projectURL: root)
                let frame = built.compositor.render(sourceImage: source, at: .zero)
                let pixels = rgbaPixels(in: frame)
                let width = Int(built.compositor.renderSize.width)
                let height = Int(built.compositor.renderSize.height)
                for (x, y) in [(1, 1), (width - 2, 1), (1, height - 2), (width - 2, height - 2)] {
                    let index = (y * width + x) * 4
                    #expect(pixels[index] < 10 && pixels[index + 1] > 240 && pixels[index + 2] < 10)
                }
                let center = ((height / 2) * width + width / 2) * 4
                #expect(pixels[center + 1] < 10)
            }
        }
    }

    private func fixtureProject() -> RecordingProject {
        RecordingProject(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            recording: RecordingMetadata(
                source: CaptureSourceDescriptor(
                    kind: .display,
                    sourceID: 1,
                    title: "Fixture",
                    applicationName: nil,
                    frame: CodableRect(CGRect(x: 0, y: 0, width: 320, height: 180)),
                    scaleFactor: 1
                ),
                width: 320,
                height: 180,
                framesPerSecond: 60,
                duration: 1,
                includesSystemAudio: false,
                includesMicrophone: false,
                videoRelativePath: "media/screen.mov",
                eventsRelativePath: "events/input-events.json"
            )
        )
    }

    private func cursorEvent(
        timestamp: Double = 0,
        x: Double,
        y: Double
    ) -> RecordedInputEvent {
        RecordedInputEvent(
            timestamp: timestamp,
            type: .mouseMoved,
            position: CodablePoint(CGPoint(x: x, y: y)),
            buttonNumber: 0,
            scrollDeltaX: nil,
            scrollDeltaY: nil,
            keyCode: nil,
            flags: 0
        )
    }

    private func rgbaPixels(in image: CIImage) -> [UInt8] {
        let bounds = image.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        pixels.withUnsafeMutableBytes { buffer in
            context.render(
                image,
                toBitmap: buffer.baseAddress!,
                rowBytes: rowBytes,
                bounds: bounds,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        return pixels
    }

    private func changedPixelSize(
        between first: [UInt8],
        and second: [UInt8],
        width: Int
    ) -> CGSize {
        guard first.count == second.count, width > 0 else { return .zero }

        var minimumX = width
        var minimumY = first.count / 4 / width
        var maximumX = -1
        var maximumY = -1
        for pixelIndex in 0..<(first.count / 4) {
            let byteIndex = pixelIndex * 4
            guard first[byteIndex..<(byteIndex + 4)] != second[byteIndex..<(byteIndex + 4)] else {
                continue
            }
            let x = pixelIndex % width
            let y = pixelIndex / width
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }

        guard maximumX >= minimumX, maximumY >= minimumY else { return .zero }
        return CGSize(
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }

    @MainActor
    private func playerPixels(
        asset: AVAsset,
        composition: AVVideoComposition,
        at time: CMTime
    ) async throws -> [UInt8] {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = composition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
        player.playImmediately(atRate: 1)
        defer { player.pause() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            let itemTime = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: itemTime) {
                if let pixelBuffer = output.copyPixelBuffer(
                    forItemTime: itemTime,
                    itemTimeForDisplay: nil
                ) {
                    return bgraPixels(in: pixelBuffer)
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PreviewHarnessError.noFrame
    }

    private func bgraPixels(in pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let outputRowBytes = width * 4
        let source = CVPixelBufferGetBaseAddress(pixelBuffer)!
        var pixels = [UInt8](repeating: 0, count: outputRowBytes * height)
        pixels.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                destination.baseAddress!
                    .advanced(by: row * outputRowBytes)
                    .copyMemory(
                        from: source.advanced(by: row * sourceRowBytes),
                        byteCount: outputRowBytes
                    )
            }
        }
        return pixels
    }

    private func createStaticFixtureVideo(at url: URL, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw PreviewHarnessError.writerConfigurationUnsupported
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? PreviewHarnessError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw PreviewHarnessError.noPixelBufferPool
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { throw PreviewHarnessError.noPixelBuffer }
        let source = CIImage(
            color: CIColor(red: 0.08, green: 0.42, blue: 0.73, alpha: 1)
        ).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        CIContext().render(source, to: pixelBuffer)

        let clock = ContinuousClock()
        for frame in [0, 29] {
            let deadline = clock.now.advanced(by: .seconds(2))
            while !input.isReadyForMoreMediaData, clock.now < deadline {
                await Task.yield()
            }
            guard input.isReadyForMoreMediaData else {
                throw PreviewHarnessError.writerNotReady
            }
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: Int64(frame), timescale: 30)
            ) else {
                throw writer.error ?? PreviewHarnessError.writerAppendFailed
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        #expect(writer.status == .completed)
    }
}

private final class StaticCameraFrameProvider: CameraFrameProviding {
    var lastTime: CMTime?
    private let image: CIImage

    init(image: CIImage) {
        self.image = image
    }

    func frame(at time: CMTime) -> CIImage? {
        lastTime = time
        return image
    }
}

private enum PreviewHarnessError: Error {
    case noFrame
    case noPixelBufferPool
    case noPixelBuffer
    case writerNotReady
    case writerConfigurationUnsupported
    case writerStartFailed
    case writerAppendFailed
}
