import SwiftUI

struct DesktopWallpaperPicker: View {
    let select: (DesktopWallpaper) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wallpapers: [DesktopWallpaper] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Desktop backgrounds").font(.title2.weight(.semibold))
                    Text("Available images on this Mac. Saved with your project as a still.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if wallpapers.isEmpty {
                ContentUnavailableView("No desktop images available", systemImage: "photo",
                    description: Text("Use Choose image to add a background from your files."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 18) {
                        ForEach(wallpapers) { wallpaper in
                            Button {
                                select(wallpaper)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Image(nsImage: wallpaper.thumbnail).resizable().scaledToFill()
                                        .frame(width: 172, height: 108)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15)))
                                    Text(wallpaper.name).font(.callout).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(wallpaper.name)
                            .accessibilityLabel("Use \(wallpaper.name) background")
                        }
                    }.padding(2)
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 520)
        .background(.ultraThinMaterial)
        .task {
            wallpapers = await DesktopWallpaper.available()
            isLoading = false
        }
    }
}
