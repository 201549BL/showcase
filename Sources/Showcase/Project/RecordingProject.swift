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
    var motionBlur: MotionBlurSettings?
    var cameraOverlay: CameraOverlaySettings?
    var cameraSegments: [CameraSegment]?
    var cameraEmphases: [CameraEmphasis]?
    var suppressedAutomaticCameraZoomIDs: [UUID]?
    var timeline: TimelineSettings?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        recording: RecordingMetadata,
        canvas: CanvasSettings = .default,
        cursor: CursorSettings = .default,
        zoomSegments: [ZoomSegment] = [],
        zoomBehavior: ZoomBehaviorSettings = .calm,
        motionBlur: MotionBlurSettings = .default,
        cameraOverlay: CameraOverlaySettings? = nil,
        cameraSegments: [CameraSegment]? = nil,
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
        self.motionBlur = motionBlur
        self.cameraOverlay = cameraOverlay
        self.cameraSegments = cameraSegments
        self.timeline = timeline
    }

    var resolvedZoomBehavior: ZoomBehaviorSettings {
        guard let zoomBehavior else { return .legacy }
        return zoomBehavior.applying(zoomBehavior.preset)
    }

    var resolvedMotionBlur: MotionBlurSettings {
        motionBlur ?? .disabled
    }

    var resolvedCameraOverlay: CameraOverlaySettings {
        cameraOverlay ?? .default
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
    var cameraVideoRelativePath: String? = nil
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
    var backgroundImage: BackgroundImageAsset? = nil

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

struct MotionBlurSettings: Codable, Equatable {
    var amount: Double

    static let `default` = MotionBlurSettings(amount: 0.5)
    static let disabled = MotionBlurSettings(amount: 0)
}

struct CameraOverlaySettings: Codable, Equatable {
    enum SizingMode: String, Codable, CaseIterable, Identifiable {
        case adaptive
        case fixed

        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    enum Corner: String, Codable, CaseIterable, Identifiable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var id: String { rawValue }
    }

    var isVisible: Bool
    var size: Double
    var corner: Corner
    var sizingMode: SizingMode?
    var isMirrored: Bool? = nil

    // Older recordings were always mirrored. Preserve that appearance when loading them.
    var resolvedIsMirrored: Bool { isMirrored ?? true }

    var resolvedSizingMode: SizingMode { sizingMode ?? .fixed }

    static let `default` = CameraOverlaySettings(
        isVisible: true,
        size: 0.28,
        corner: .bottomRight,
        sizingMode: .adaptive
    )
}

struct TimelineSettings: Codable, Equatable {
    var trimStart: Double
    var trimEnd: Double?

    static let `default` = TimelineSettings(trimStart: 0, trimEnd: nil)
}

struct ZoomBehaviorSettings: Codable, Equatable {
    enum MotionStyle: String, Codable, CaseIterable, Identifiable {
        case focused
        case smooth

        var id: String { rawValue }

        var displayName: String { rawValue.capitalized }
    }

    enum Preset: String, Codable, CaseIterable, Identifiable {
        case calm
        case focused
        case off
        case custom

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .calm: return "Smart"
            case .focused: return "Close-up"
            case .off: return "Off"
            case .custom: return "Custom"
            }
        }
    }

    var preset: Preset
    var scale: Double
    var transitionDuration: Double
    var holdDuration: Double
    var groupingInterval: Double
    var overviewPaddingFraction: Double
    var motionStyle: MotionStyle?

    var resolvedMotionStyle: MotionStyle { motionStyle ?? .focused }

    static let calm = ZoomBehaviorSettings(
        preset: .calm,
        scale: 1.95,
        transitionDuration: 0.55,
        holdDuration: 2,
        groupingInterval: 2.8,
        overviewPaddingFraction: 0.14,
        motionStyle: .focused
    )

    static let focused = ZoomBehaviorSettings(
        preset: .focused,
        scale: 2.5,
        transitionDuration: 0.35,
        holdDuration: 0.75,
        groupingInterval: 1.05,
        overviewPaddingFraction: 0.09,
        motionStyle: .focused
    )

    static let legacy = ZoomBehaviorSettings(
        preset: .custom,
        scale: 1.6,
        transitionDuration: 0.4,
        holdDuration: 0.9,
        groupingInterval: 1.6,
        overviewPaddingFraction: 0.12,
        motionStyle: .focused
    )

    func applying(_ preset: Preset) -> ZoomBehaviorSettings {
        let motionStyle = resolvedMotionStyle
        switch preset {
        case .calm:
            var settings = Self.calm
            settings.motionStyle = motionStyle
            return settings
        case .focused:
            var settings = Self.focused
            settings.motionStyle = motionStyle
            return settings
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
    static let defaultCursorBoundaryFraction = 0.65
    static let cursorBoundaryRange = 0.35...0.9

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
    var entranceDuration: Double?
    var reframes: [ZoomReframe]
    var cursorBoundaryFraction: Double?

    init(
        id: UUID,
        startTime: Double,
        focusTime: Double,
        endTime: Double,
        focusPoint: CodablePoint,
        scale: Double,
        source: Source,
        transitionDuration: Double? = nil,
        reframes: [ZoomReframe] = [],
        cursorBoundaryFraction: Double? = nil,
        entranceDuration: Double? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.focusTime = focusTime
        self.endTime = endTime
        self.focusPoint = focusPoint
        self.scale = scale
        self.source = source
        self.transitionDuration = transitionDuration
        self.entranceDuration = entranceDuration
        self.reframes = reframes
        self.cursorBoundaryFraction = cursorBoundaryFraction
    }

    /// Keep preferred durations separate from the fitted focus time, so shortening
    /// and then extending a block restores its transitions instead of stretching them.
    var preferredEntranceDuration: Double {
        if let entranceDuration, entranceDuration.isFinite, entranceDuration > 0 {
            return entranceDuration
        }
        let legacyDuration = focusTime - startTime
        let available = endTime - startTime
        if legacyDuration > 0, legacyDuration + preferredExitDuration <= available + 0.000_001 {
            return legacyDuration
        }
        // Older resize operations could leave focus at the end of the block.
        return preferredExitDuration
    }

    var preferredExitDuration: Double {
        guard let transitionDuration, transitionDuration.isFinite, transitionDuration > 0 else { return 0.5 }
        return transitionDuration
    }

    var timing: ZoomTiming {
        ZoomTiming(start: startTime, end: endTime,
                   entrance: preferredEntranceDuration, exit: preferredExitDuration)
    }

    mutating func normalizeTiming() {
        entranceDuration = preferredEntranceDuration
        focusTime = timing.focusTime
    }

    /// Authored positions retain their composition and edge-follow behavior.
    var usesProportionalCursorPan: Bool {
        source == .automatic && reframes.isEmpty
    }

    var resolvedCursorBoundaryFraction: Double {
        min(
            Self.cursorBoundaryRange.upperBound,
            max(
                Self.cursorBoundaryRange.lowerBound,
                cursorBoundaryFraction ?? Self.defaultCursorBoundaryFraction
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startTime
        case focusTime
        case endTime
        case focusPoint
        case scale
        case source
        case transitionDuration
        case entranceDuration
        case reframes
        case cursorBoundaryFraction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startTime = try container.decode(Double.self, forKey: .startTime)
        focusTime = try container.decode(Double.self, forKey: .focusTime)
        endTime = try container.decode(Double.self, forKey: .endTime)
        focusPoint = try container.decode(CodablePoint.self, forKey: .focusPoint)
        scale = try container.decode(Double.self, forKey: .scale)
        source = try container.decode(Source.self, forKey: .source)
        transitionDuration = try container.decodeIfPresent(
            Double.self,
            forKey: .transitionDuration
        )
        entranceDuration = try container.decodeIfPresent(Double.self, forKey: .entranceDuration)
        reframes = try container.decodeIfPresent(
            [ZoomReframe].self,
            forKey: .reframes
        ) ?? []
        cursorBoundaryFraction = try container.decodeIfPresent(
            Double.self,
            forKey: .cursorBoundaryFraction
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(focusTime, forKey: .focusTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(focusPoint, forKey: .focusPoint)
        try container.encode(scale, forKey: .scale)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(transitionDuration, forKey: .transitionDuration)
        try container.encodeIfPresent(entranceDuration, forKey: .entranceDuration)
        if !reframes.isEmpty {
            try container.encode(reframes, forKey: .reframes)
        }
        try container.encodeIfPresent(cursorBoundaryFraction, forKey: .cursorBoundaryFraction)
    }
}

/// The block owns entrance, hold, and exit. Only the hold grows during resizing;
/// transitions compress proportionally when the block is too short for both.
struct ZoomTiming {
    let entranceDuration: Double
    let exitDuration: Double
    let focusTime: Double
    let exitStart: Double

    init(start: Double, end: Double, entrance: Double, exit: Double) {
        let duration = max(0, end - start)
        let factor = min(1, duration / max(0.000_001, entrance + exit))
        entranceDuration = entrance * factor
        exitDuration = exit * factor
        focusTime = start + entranceDuration
        exitStart = end - exitDuration
    }
}

struct ZoomReframe: Codable, Equatable, Identifiable {
    let id: UUID
    var time: Double
    var focusPoint: CodablePoint
    var scale: Double

    init(
        id: UUID = UUID(),
        time: Double,
        focusPoint: CodablePoint,
        scale: Double
    ) {
        self.id = id
        self.time = time
        self.focusPoint = focusPoint
        self.scale = scale
    }
}
