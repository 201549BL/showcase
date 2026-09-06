import CoreGraphics
import Foundation

struct CanvasGeometry: Equatable {
    let canvasSize: CGSize
    let screenRect: CGRect
    let scaledCornerRadius: Double
    let scaledShadowRadius: Double

    init(
        project: RecordingProject,
        quality: ExportQuality,
        maximumCanvasDimension: Double? = nil
    ) {
        let sourceSize = CGSize(
            width: project.recording.width,
            height: project.recording.height
        )
        let qualityCanvasSize = quality.canvasSize(
            aspectRatio: project.canvas.aspectRatio,
            sourceSize: sourceSize
        )
        canvasSize = Self.scaledCanvasSize(
            qualityCanvasSize,
            maximumDimension: maximumCanvasDimension
        )

        let designScale = canvasSize.height / 1_080
        let padding = max(0, project.canvas.padding * designScale)
        let available = CGRect(origin: .zero, size: canvasSize)
            .insetBy(dx: padding, dy: padding)
        screenRect = Self.aspectFit(sourceSize, inside: available)
        scaledCornerRadius = max(0, project.canvas.cornerRadius * designScale)
        scaledShadowRadius = max(0, project.canvas.shadowRadius * designScale)
    }

    private static func aspectFit(_ size: CGSize, inside rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }

        let scale = min(rect.width / size.width, rect.height / size.height)
        let fittedSize = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: rect.midX - fittedSize.width / 2,
            y: rect.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private static func scaledCanvasSize(
        _ size: CGSize,
        maximumDimension: Double?
    ) -> CGSize {
        guard
            let maximumDimension,
            maximumDimension > 0,
            max(size.width, size.height) > maximumDimension
        else { return size }

        let scale = maximumDimension / max(size.width, size.height)
        return CGSize(
            width: even(size.width * scale),
            height: even(size.height * scale)
        )
    }

    private static func even(_ value: Double) -> Double {
        let rounded = max(2, Int(value.rounded()))
        return Double(rounded.isMultiple(of: 2) ? rounded : rounded + 1)
    }
}

enum ExportQuality: String, Codable, CaseIterable, Identifiable {
    case hd
    case ultraHD

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hd: return "1080p"
        case .ultraHD: return "4K"
        }
    }

    func canvasSize(
        aspectRatio: CanvasSettings.AspectRatio,
        sourceSize: CGSize
    ) -> CGSize {
        let longEdge: Double = self == .ultraHD ? 3_840 : 1_920
        let shortEdge: Double = self == .ultraHD ? 2_160 : 1_080

        switch aspectRatio {
        case .landscape:
            return CGSize(width: longEdge, height: shortEdge)
        case .vertical:
            return CGSize(width: shortEdge, height: longEdge)
        case .square:
            return CGSize(width: shortEdge, height: shortEdge)
        case .source:
            guard sourceSize.width > 0, sourceSize.height > 0 else {
                return CGSize(width: longEdge, height: shortEdge)
            }
            let scale = min(1, longEdge / max(sourceSize.width, sourceSize.height))
            return CGSize(
                width: even(sourceSize.width * scale),
                height: even(sourceSize.height * scale)
            )
        }
    }

    private func even(_ value: Double) -> Double {
        let integer = max(2, Int(value.rounded()))
        return Double(integer.isMultiple(of: 2) ? integer : integer + 1)
    }
}
