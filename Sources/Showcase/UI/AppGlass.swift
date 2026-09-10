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

/// Floating controls need an edge against both bright windows and dark desktops.
struct RecorderGlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .appGlassSurface(in: Capsule(), tint: colorScheme == .dark
                ? .white.opacity(0.06) : .black.opacity(0.06))
            .overlay(Capsule().strokeBorder(.black.opacity(0.22), lineWidth: 1))
            .overlay(Capsule().inset(by: 1).strokeBorder(.white.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
    }
}
