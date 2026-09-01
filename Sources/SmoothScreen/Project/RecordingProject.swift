import CoreGraphics
import Foundation

struct RecordingProject: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let id: UUID
    let createdAt: Date
    var completedAt: Date?
    var recording: RecordingMetadata
    var canvas: CanvasSettings
    var cursor: CursorSettings
    var zoomSegments: [ZoomSegment]
    var zoomBehavior: ZoomBehaviorSettings?
    var timeline: TimelineSettings?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        recording: RecordingMetadata,
        canvas: CanvasSettings = .default,
        cursor: CursorSettings = .default,
        zoomSegments: [ZoomSegment] = [],
        zoomBehavior: ZoomBehaviorSettings = .calm,
        timeline: TimelineSettings = .default
    ) {
        version = Self.currentVersion
        self.id = id
        self.createdAt = createdAt
        self.recording = recording
        self.canvas = canvas
        self.cursor = cursor
        self.zoomSegments = zoomSegments
        self.zoomBehavior = zoomBehavior
        self.timeline = timeline
    }

    var resolvedZoomBehavior: ZoomBehaviorSettings {
        zoomBehavior ?? .legacy
    }
}

struct RecordingMetadata: Codable, Equatable {
    var source: CaptureSourceDescriptor
    var width: Int
    var height: Int
    var framesPerSecond: Int
    var duration: Double?
    var includesSystemAudio: Bool
    var includesMicrophone: Bool?
    var videoRelativePath: String
    var eventsRelativePath: String
}

struct CaptureSourceDescriptor: Codable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case display
        case window
    }

    let kind: Kind
    let sourceID: UInt32
    let title: String
    let applicationName: String?
    let frame: CodableRect
    let scaleFactor: Double

    var id: String { "\(kind.rawValue)-\(sourceID)" }

    var displayName: String {
        if let applicationName, !applicationName.isEmpty {
            return "\(applicationName) — \(title)"
        }
        return title
    }
}

struct CodableRect: Codable, Equatable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct CodablePoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct CanvasSettings: Codable, Equatable {
    enum AspectRatio: String, Codable, CaseIterable {
        case source
        case landscape
        case square
        case vertical
    }

    var aspectRatio: AspectRatio
    var padding: Double
    var cornerRadius: Double
    var shadowRadius: Double
    var backgroundStartHex: String
    var backgroundEndHex: String

    static let `default` = CanvasSettings(
        aspectRatio: .landscape,
        padding: 72,
        cornerRadius: 18,
        shadowRadius: 30,
        backgroundStartHex: "#6D5DFB",
        backgroundEndHex: "#C66BFF"
    )
}

struct CursorSettings: Codable, Equatable {
    var scale: Double
    var smoothing: Double
    var hideAfter: Double
    var showsClickAnimation: Bool

    static let `default` = CursorSettings(
        scale: 1.4,
        smoothing: 0.65,
        hideAfter: 2,
        showsClickAnimation: true
    )
}

struct TimelineSettings: Codable, Equatable {
    var trimStart: Double
    var trimEnd: Double?

    static let `default` = TimelineSettings(trimStart: 0, trimEnd: nil)
}

struct ZoomBehaviorSettings: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        case calm
        case focused
        case off
        case custom

        var id: String { rawValue }

        var displayName: String { rawValue.capitalized }
    }

    var preset: Preset
    var scale: Double
    var transitionDuration: Double
    var holdDuration: Double
    var groupingInterval: Double
    var overviewPaddingFraction: Double

    static let calm = ZoomBehaviorSettings(
        preset: .calm,
        scale: 1.4,
        transitionDuration: 0.65,
        holdDuration: 1.3,
        groupingInterval: 2.4,
        overviewPaddingFraction: 0.18
    )

    static let focused = ZoomBehaviorSettings(
        preset: .focused,
        scale: 1.75,
        transitionDuration: 0.35,
        holdDuration: 0.75,
        groupingInterval: 1.2,
        overviewPaddingFraction: 0.1
    )

    static let legacy = ZoomBehaviorSettings(
        preset: .custom,
        scale: 1.6,
        transitionDuration: 0.4,
        holdDuration: 0.9,
        groupingInterval: 1.6,
        overviewPaddingFraction: 0.12
    )

    func applying(_ preset: Preset) -> ZoomBehaviorSettings {
        switch preset {
        case .calm:
            return .calm
        case .focused:
            return .focused
        case .off:
            var settings = self
            settings.preset = .off
            return settings
        case .custom:
            var settings = self
            settings.preset = .custom
            return settings
        }
    }
}

struct ZoomSegment: Codable, Equatable, Identifiable {
    enum Source: String, Codable {
        case automatic
        case manual
    }

    let id: UUID
    var startTime: Double
    var focusTime: Double
    var endTime: Double
    var focusPoint: CodablePoint
    var scale: Double
    var source: Source
    var transitionDuration: Double?

    init(
        id: UUID,
        startTime: Double,
        focusTime: Double,
        endTime: Double,
        focusPoint: CodablePoint,
        scale: Double,
        source: Source,
        transitionDuration: Double? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.focusTime = focusTime
        self.endTime = endTime
        self.focusPoint = focusPoint
        self.scale = scale
        self.source = source
        self.transitionDuration = transitionDuration
    }
}
