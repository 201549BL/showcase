import SwiftUI

/// Category navigation stays available when the inspector is showing a zoom.
struct SidebarTabs: View {
    let selection: String?
    let showsCamera: Bool
    var tint: Color? = nil
    let select: (String) -> Void

    private var tabs: [(title: String, symbol: String)] {
        var items = [("Frame", "rectangle.inset.filled"),
                     ("Cursor", "cursorarrow"),
                     ("Motion", "wand.and.stars")]
        if showsCamera { items.append(("Camera", "video")) }
        return items
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.title) { tab in
                Button { select(tab.title) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .frame(height: 19)
                        Text(tab.title).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selection == tab.title ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .contentShape(Capsule())
                    .background {
                        if selection == tab.title {
                            SidebarTabHighlight()
                        }
                    }
                }
                .buttonStyle(SidebarTabButtonStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab.title ? .isSelected : [])
                .help("\(tab.title) settings")
            }
        }
        .padding(5)
        .appGlassSurface(in: Capsule(), tint: tint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video settings tabs")
    }
}

/// The selected segment is a translucent lens inside the native glass bar.
/// A second glass effect here would sample another glass surface and look flat.
private struct SidebarTabHighlight: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill(LinearGradient(
                colors: [.white.opacity(colorScheme == .dark ? 0.16 : 0.65),
                         .white.opacity(colorScheme == .dark ? 0.1 : 0.45)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.06), .white.opacity(0.14)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.5
                )
            }
    }
}

private struct SidebarTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverFeedback(configuration: configuration)
    }

    private struct HoverFeedback: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background {
                    Capsule()
                        .fill(.primary.opacity(configuration.isPressed ? 0.09 : hovered ? 0.04 : 0))
                }
                .onHover { hovered = $0 }
        }
    }
}
