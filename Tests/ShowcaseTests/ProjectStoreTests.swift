import Foundation
import Testing
@testable import Showcase

@Suite("Project persistence")
struct ProjectStoreTests {
    @Test("Creates a recoverable project directory")
    func createsProjectDirectory() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = ProjectStore(projectsDirectory: temporaryRoot)
        let locations = try store.createProjectDirectory(named: "Demo / Recording")

        #expect(locations.projectURL.lastPathComponent == "Demo - Recording.screenproject")
        #expect(FileManager.default.fileExists(atPath: locations.projectURL.path))
        #expect(FileManager.default.fileExists(atPath: locations.videoURL.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: locations.eventsURL.deletingLastPathComponent().path))
    }

    @Test("Avoids overwriting an existing project")
    func createsUniqueProjectNames() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = ProjectStore(projectsDirectory: temporaryRoot)
        let first = try store.createProjectDirectory(named: "Demo")
        let second = try store.createProjectDirectory(named: "Demo")

        #expect(first.projectURL.lastPathComponent == "Demo.screenproject")
        #expect(second.projectURL.lastPathComponent == "Demo 2.screenproject")
    }

    @Test("Writes project metadata and input events")
    func writesProjectFiles() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = ProjectStore(projectsDirectory: temporaryRoot)
        let locations = try store.createProjectDirectory(named: "Round Trip")
        let source = CaptureSourceDescriptor(
            kind: .display,
            sourceID: 42,
            title: "Test Display",
            applicationName: nil,
            frame: CodableRect(CGRect(x: 0, y: 0, width: 1_440, height: 900)),
            scaleFactor: 2
        )
        let project = RecordingProject(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            recording: RecordingMetadata(
                source: source,
                width: 2_880,
                height: 1_800,
                framesPerSecond: 60,
                duration: 5,
                includesSystemAudio: true,
                includesMicrophone: false,
                videoRelativePath: "media/screen.mov",
                eventsRelativePath: "events/input-events.json",
                cameraVideoRelativePath: "media/camera.mov"
            ),
            cameraOverlay: .default
        )
        let events = [
            RecordedInputEvent(
                timestamp: 1.25,
                type: .leftMouseDown,
                position: CodablePoint(CGPoint(x: 100, y: 200)),
                buttonNumber: 0,
                scrollDeltaX: nil,
                scrollDeltaY: nil,
                keyCode: nil,
                flags: 0,
                cursorStyle: .pointingHand
            )
        ]

        try store.save(project, to: locations)
        try store.save(events: events, to: locations)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let savedProject = try decoder.decode(
            RecordingProject.self,
            from: Data(contentsOf: locations.projectJSONURL)
        )
        let savedEvents = try decoder.decode(
            [RecordedInputEvent].self,
            from: Data(contentsOf: locations.eventsURL)
        )

        #expect(savedProject == project)
        #expect(savedEvents == events)
    }

    @Test("Reads input events recorded before live window bounds were added")
    func readsLegacyInputEvents() throws {
        let legacyJSON = """
        [{
          "timestamp": 1.25,
          "type": "mouseMoved",
          "position": {"x": 100, "y": 200},
          "flags": 0
        }]
        """

        let events = try JSONDecoder().decode(
            [RecordedInputEvent].self,
            from: Data(legacyJSON.utf8)
        )

        #expect(events.count == 1)
        #expect(events[0].sourceFrame == nil)
        #expect(events[0].position == CodablePoint(CGPoint(x: 100, y: 200)))
        #expect(events[0].cursorStyle == nil)
    }

    @Test("Reads projects created before zoom behavior settings")
    func readsLegacyZoomProject() throws {
        let source = CaptureSourceDescriptor(
            kind: .display,
            sourceID: 1,
            title: "Display",
            applicationName: nil,
            frame: CodableRect(CGRect(x: 0, y: 0, width: 1_600, height: 900)),
            scaleFactor: 1
        )
        let project = RecordingProject(
            recording: RecordingMetadata(
                source: source,
                width: 1_600,
                height: 900,
                framesPerSecond: 60,
                duration: 3,
                includesSystemAudio: false,
                includesMicrophone: false,
                videoRelativePath: "media/screen.mov",
                eventsRelativePath: "events/input-events.json"
            ),
            zoomSegments: [
                ZoomSegment(
                    id: UUID(),
                    startTime: 1,
                    focusTime: 1.4,
                    endTime: 2.5,
                    focusPoint: CodablePoint(CGPoint(x: 800, y: 450)),
                    scale: 1.6,
                    source: .automatic,
                    transitionDuration: 0.4,
                    cursorBoundaryFraction: 0.5
                )
            ]
        )
        let encoded = try JSONEncoder().encode(project)
        var json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        json.removeValue(forKey: "zoomBehavior")
        json.removeValue(forKey: "motionBlur")
        var segments = try #require(json["zoomSegments"] as? [[String: Any]])
        #expect(segments[0]["cursorBoundaryFraction"] as? Double == 0.5)
        segments[0].removeValue(forKey: "transitionDuration")
        segments[0].removeValue(forKey: "cursorBoundaryFraction")
        json["zoomSegments"] = segments

        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: legacyData)

        #expect(decoded.zoomBehavior == nil)
        #expect(decoded.resolvedZoomBehavior == .legacy)
        #expect(decoded.motionBlur == nil)
        #expect(decoded.resolvedMotionBlur == .disabled)
        #expect(decoded.zoomSegments[0].transitionDuration == nil)
        #expect(decoded.zoomSegments[0].reframes.isEmpty)
        #expect(decoded.zoomSegments[0].cursorBoundaryFraction == nil)
        #expect(decoded.zoomSegments[0].resolvedCursorBoundaryFraction == 0.65)
    }

    @Test("Reads zoom settings saved before camera motion styles")
    func readsZoomSettingsWithoutMotionStyle() throws {
        let project = RecordingProject(
            recording: RecordingMetadata(
                source: CaptureSourceDescriptor(
                    kind: .display,
                    sourceID: 1,
                    title: "Display",
                    applicationName: nil,
                    frame: CodableRect(CGRect(x: 0, y: 0, width: 1_600, height: 900)),
                    scaleFactor: 1
                ),
                width: 1_600,
                height: 900,
                framesPerSecond: 60,
                duration: 3,
                includesSystemAudio: false,
                includesMicrophone: false,
                videoRelativePath: "media/screen.mov",
                eventsRelativePath: "events/input-events.json"
            )
        )
        let encoded = try JSONEncoder().encode(project)
        var json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var zoomBehavior = try #require(json["zoomBehavior"] as? [String: Any])
        zoomBehavior.removeValue(forKey: "motionStyle")
        json["zoomBehavior"] = zoomBehavior

        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: legacyData)

        #expect(decoded.zoomBehavior?.motionStyle == nil)
        #expect(decoded.resolvedZoomBehavior.resolvedMotionStyle == .focused)
    }
}
