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
