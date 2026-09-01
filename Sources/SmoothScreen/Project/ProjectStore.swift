import Foundation

struct ProjectStore {
    enum StoreError: LocalizedError {
        case projectAlreadyExists(URL)

        var errorDescription: String? {
            switch self {
            case .projectAlreadyExists(let url):
                return "A recording project already exists at \(url.path)."
            }
        }
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let projectsDirectory: URL?

    init(fileManager: FileManager = .default, projectsDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.projectsDirectory = projectsDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func defaultProjectsDirectory() throws -> URL {
        if let projectsDirectory {
            return projectsDirectory
        }
        let movies = try fileManager.url(
            for: .moviesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return movies.appendingPathComponent("SmoothScreen", isDirectory: true)
    }

    func createProjectDirectory(named name: String) throws -> ProjectLocations {
        let root = try defaultProjectsDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let safeName = sanitizedProjectName(name)
        let projectURL = uniqueProjectURL(in: root, preferredName: safeName)
        guard !fileManager.fileExists(atPath: projectURL.path) else {
            throw StoreError.projectAlreadyExists(projectURL)
        }

        let mediaURL = projectURL.appendingPathComponent("media", isDirectory: true)
        let eventsURL = projectURL.appendingPathComponent("events", isDirectory: true)
        try fileManager.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: eventsURL, withIntermediateDirectories: true)

        return ProjectLocations(
            projectURL: projectURL,
            projectJSONURL: projectURL.appendingPathComponent("project.json"),
            videoURL: mediaURL.appendingPathComponent("screen.mov"),
            eventsURL: eventsURL.appendingPathComponent("input-events.json")
        )
    }

    func save(_ project: RecordingProject, to locations: ProjectLocations) throws {
        let data = try encoder.encode(project)
        try data.write(to: locations.projectJSONURL, options: .atomic)
    }

    func save(events: [RecordedInputEvent], to locations: ProjectLocations) throws {
        let data = try encoder.encode(events)
        try data.write(to: locations.eventsURL, options: .atomic)
    }

    func loadProject(at projectURL: URL) throws -> RecordingProject {
        let locations = locations(for: projectURL)
        return try decoder.decode(
            RecordingProject.self,
            from: Data(contentsOf: locations.projectJSONURL)
        )
    }

    func loadEvents(at projectURL: URL) throws -> [RecordedInputEvent] {
        let locations = locations(for: projectURL)
        return try decoder.decode(
            [RecordedInputEvent].self,
            from: Data(contentsOf: locations.eventsURL)
        )
    }

    func locations(for projectURL: URL) -> ProjectLocations {
        ProjectLocations(
            projectURL: projectURL,
            projectJSONURL: projectURL.appendingPathComponent("project.json"),
            videoURL: projectURL.appendingPathComponent("media/screen.mov"),
            eventsURL: projectURL.appendingPathComponent("events/input-events.json")
        )
    }

    private func sanitizedProjectName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = name.components(separatedBy: invalid)
        let sanitized = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Recording" : sanitized
    }

    private func uniqueProjectURL(in directory: URL, preferredName: String) -> URL {
        let initial = directory.appendingPathComponent("\(preferredName).screenproject", isDirectory: true)
        guard fileManager.fileExists(atPath: initial.path) else { return initial }

        for suffix in 2...999 {
            let candidate = directory.appendingPathComponent(
                "\(preferredName) \(suffix).screenproject",
                isDirectory: true
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent(
            "\(preferredName)-\(UUID().uuidString).screenproject",
            isDirectory: true
        )
    }
}

struct ProjectLocations: Equatable {
    let projectURL: URL
    let projectJSONURL: URL
    let videoURL: URL
    let eventsURL: URL
}
