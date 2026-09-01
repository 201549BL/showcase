import AVKit
import SwiftUI

struct ProjectEditorView: View {
    @ObservedObject var model: EditorModel
    let onClose: () -> Void

    var body: some View {
        HSplitView {
            previewPane
                .frame(minWidth: 520)
            controlsPane
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onClose) {
                    Label("New Recording", systemImage: "chevron.left")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.revealProject()
                } label: {
                    Label("Show Project", systemImage: "folder")
                }

                Button {
                    Task { await model.exportVideo() }
                } label: {
                    if model.isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExporting)
            }
        }
        .alert(item: $model.presentedError) { error in
            Alert(
                title: Text("SmoothScreen couldn’t continue"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.92)
                VideoPlayer(player: model.player)
                    .aspectRatio(model.canvasAspectRatio, contentMode: .fit)
                    .padding(24)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    model.addManualZoom()
                } label: {
                    Label("Add Zoom Here", systemImage: "plus.magnifyingglass")
                }
                .help("Adds a manual zoom around the current playhead")

                Button {
                    model.regenerateAutomaticZooms()
                } label: {
                    Label("Regenerate", systemImage: "wand.and.stars")
                }

                Spacer()

                Text("\(model.project.zoomSegments.count) zooms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    private var controlsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                outputSection
                styleSection
                cursorSection
                zoomSection

                if model.lastExportURL != nil {
                    Button("Show Last Export in Finder") {
                        model.revealLastExport()
                    }
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var outputSection: some View {
        editorSection("Output") {
            Picker("Format", selection: binding(\.canvas.aspectRatio)) {
                ForEach(CanvasSettings.AspectRatio.allCases, id: \.self) { ratio in
                    Text(aspectName(ratio)).tag(ratio)
                }
            }
            .pickerStyle(.segmented)

            Picker("Quality", selection: $model.quality) {
                ForEach(ExportQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .onChange(of: model.quality) {
                model.projectDidChange()
            }

            slider(
                "Trim start",
                value: Binding(get: { model.trimStart }, set: model.setTrimStart),
                range: 0...max(0.1, model.recordingDuration - 0.1)
            )
            slider(
                "Trim end",
                value: Binding(get: { model.trimEnd }, set: model.setTrimEnd),
                range: 0.1...model.recordingDuration
            )
        }
    }

    private var styleSection: some View {
        editorSection("Frame") {
            Text("Background")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                ForEach(BackgroundPreset.allCases) { preset in
                    Button {
                        model.applyBackground(preset)
                    } label: {
                        Circle()
                            .fill(backgroundGradient(preset))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.white.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    .help(preset.displayName)
                }
            }

            slider("Padding", value: binding(\.canvas.padding), range: 0...160)
            slider("Corners", value: binding(\.canvas.cornerRadius), range: 0...48)
            slider("Shadow", value: binding(\.canvas.shadowRadius), range: 0...60)
        }
    }

    private var cursorSection: some View {
        editorSection("Cursor") {
            slider("Size", value: binding(\.cursor.scale), range: 0.75...2.5)
            slider("Smoothing", value: binding(\.cursor.smoothing), range: 0...1)
            slider("Hide after", value: binding(\.cursor.hideAfter), range: 0.5...5)
            Toggle("Click animation", isOn: binding(\.cursor.showsClickAnimation))
        }
    }

    private var zoomSection: some View {
        editorSection("Zooms") {
            if model.project.zoomSegments.isEmpty {
                Text("No clicks produced an automatic zoom. Move the playhead and add one manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.project.zoomSegments.enumerated()), id: \.element.id) { index, zoom in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(
                                timeLabel(zoom.startTime),
                                systemImage: zoom.source == .automatic ? "wand.and.stars" : "hand.draw"
                            )
                            .font(.caption)

                            Spacer()

                            Button(role: .destructive) {
                                model.deleteZoom(id: zoom.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }

                        slider(
                            "Scale",
                            value: zoomScaleBinding(index: index),
                            range: 1.1...2.5
                        )
                        slider(
                            "Focus X",
                            value: zoomBinding(index: index, keyPath: \.focusPoint.x),
                            range: 0...Double(model.project.recording.width)
                        )
                        slider(
                            "Focus Y",
                            value: zoomBinding(index: index, keyPath: \.focusPoint.y),
                            range: 0...Double(model.project.recording.height)
                        )
                        slider(
                            "Start",
                            value: zoomBinding(index: index, keyPath: \.startTime),
                            range: 0...model.recordingDuration
                        )
                        slider(
                            "End",
                            value: zoomBinding(index: index, keyPath: \.endTime),
                            range: 0...model.recordingDuration
                        )
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func editorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Slider(value: value, in: range)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<RecordingProject, Value>) -> Binding<Value> {
        Binding(
            get: { model.project[keyPath: keyPath] },
            set: { value in
                model.project[keyPath: keyPath] = value
                model.projectDidChange()
            }
        )
    }

    private func zoomScaleBinding(index: Int) -> Binding<Double> {
        Binding(
            get: { model.project.zoomSegments[index].scale },
            set: { value in
                guard model.project.zoomSegments.indices.contains(index) else { return }
                model.project.zoomSegments[index].scale = value
                model.projectDidChange()
            }
        )
    }

    private func zoomBinding(
        index: Int,
        keyPath: WritableKeyPath<ZoomSegment, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.project.zoomSegments[index][keyPath: keyPath] },
            set: { value in
                guard model.project.zoomSegments.indices.contains(index) else { return }
                if keyPath == \.startTime {
                    let latestStart = max(0, model.project.zoomSegments[index].endTime - 0.1)
                    model.project.zoomSegments[index].startTime = min(value, latestStart)
                    model.project.zoomSegments[index].focusTime = max(
                        model.project.zoomSegments[index].startTime,
                        model.project.zoomSegments[index].focusTime
                    )
                } else if keyPath == \.endTime {
                    let earliestEnd = model.project.zoomSegments[index].startTime + 0.1
                    model.project.zoomSegments[index].endTime = max(value, earliestEnd)
                    model.project.zoomSegments[index].focusTime = min(
                        model.project.zoomSegments[index].endTime,
                        model.project.zoomSegments[index].focusTime
                    )
                } else {
                    model.project.zoomSegments[index][keyPath: keyPath] = value
                }
                model.projectDidChange()
            }
        )
    }

    private func aspectName(_ ratio: CanvasSettings.AspectRatio) -> String {
        switch ratio {
        case .source: return "Source"
        case .landscape: return "16:9"
        case .square: return "1:1"
        case .vertical: return "9:16"
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func backgroundGradient(_ preset: BackgroundPreset) -> LinearGradient {
        LinearGradient(
            colors: [Color(hex: preset.startHex), Color(hex: preset.endHex)],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
