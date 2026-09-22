import SwiftUI

/// Shared native glass for app chrome; the video canvas remains unframed.
extension View {
    func appGlassSurface<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(AppGlassSurface(shape: shape, tint: tint))
    }

    func appGlassButton(prominent: Bool = false) -> some View {
        modifier(AppGlassButton(prominent: prominent))
    }
}

private struct AppGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .background(tint ?? .clear, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.1), lineWidth: 1))
        }
    }
}

private struct AppGlassButton: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

/// Keep the recorder dark over any desktop with a shadow-free frosted surface.
struct RecorderGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let smoke = Color(red: 31 / 255, green: 33 / 255, blue: 40 / 255)

    func body(content: Content) -> some View {
        surface(content)
            .foregroundStyle(Color(red: 250 / 255, green: 250 / 255, blue: 253 / 255))
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if reduceTransparency {
            content.background(smoke, in: Capsule())
        } else {
            // Material keeps the frosted surface without Liquid Glass's
            // built-in active-state edge shadow.
            content
                .background(smoke.opacity(0.78), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}
