import Foundation
import Testing
@testable import SmoothScreen

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
            recording: RecordingMetadata(
                source: source,
                width: 2_880,
                height: 1_800,
                framesPerSecond: 60,
                duration: 5,
                includesSystemAudio: true,
                videoRelativePath: "media/screen.mov",
                eventsRelativePath: "events/input-events.json"
            )
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
                flags: 0
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
}
