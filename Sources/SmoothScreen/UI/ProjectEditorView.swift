import AVKit
import SwiftUI

struct ProjectEditorView: View {
    @ObservedObject var model: EditorModel
    let onClose: () -> Void
    @State private var isEditingFocus = false

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
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    model.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .help(model.undoActionName.map { "Undo \($0) (⌘Z)" } ?? "Nothing to undo")

                Button {
                    model.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
                .help(model.redoActionName.map { "Redo \($0) (⇧⌘Z)" } ?? "Nothing to redo")
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
        .onChange(of: model.selectedZoomID) {
            if model.selectedZoomID == nil {
                isEditingFocus = false
            }
        }
        .focusedSceneValue(
            \.editorHistoryActions,
            EditorHistoryActions(
                undoActionName: model.undoActionName,
                redoActionName: model.redoActionName,
                undo: model.undo,
                redo: model.redo
            )
        )
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            previewStage

            Divider()

            ZoomTimelineView(model: model)
                .frame(height: 112)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

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

                Button {
                    isEditingFocus.toggle()
                    if isEditingFocus, let zoom = model.selectedZoom {
                        model.seek(to: zoom.focusTime)
                    }
                } label: {
                    Label(
                        isEditingFocus ? "Done Focusing" : "Set Focus",
                        systemImage: isEditingFocus ? "checkmark.circle.fill" : "scope"
                    )
                }
                .buttonStyle(.bordered)
                .tint(isEditingFocus ? .accentColor : nil)
                .disabled(model.selectedZoom == nil)
                .help("Choose the focal point directly in the preview")

                Spacer()

                Text("\(model.project.zoomSegments.count) zooms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    private var previewStage: some View {
        GeometryReader { proxy in
            let availableSize = CGSize(
                width: max(1, proxy.size.width - 48),
                height: max(1, proxy.size.height - 48)
            )
            let previewSize = aspectFit(
                aspectRatio: model.canvasAspectRatio,
                inside: availableSize
            )

            ZStack {
                Color.black.opacity(0.92)

                ZStack {
                    VideoPlayer(player: model.player)

                    if isEditingFocus, let zoom = model.selectedZoom {
                        PreviewFocusOverlay(model: model, zoom: zoom)
                    }
                }
                .frame(width: previewSize.width, height: previewSize.height)
            }
        }
        .frame(minHeight: 260)
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
            Picker(
                "Format",
                selection: binding(\.canvas.aspectRatio, actionName: "Change Format")
            ) {
                ForEach(CanvasSettings.AspectRatio.allCases, id: \.self) { ratio in
                    Text(aspectName(ratio)).tag(ratio)
                }
            }
            .pickerStyle(.segmented)

            Picker(
                "Quality",
                selection: Binding(get: { model.quality }, set: model.setQuality)
            ) {
                ForEach(ExportQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            slider(
                "Trim start",
                value: Binding(get: { model.trimStart }, set: model.setTrimStart),
                range: 0...max(0.1, model.recordingDuration - 0.1),
                actionName: "Trim Start"
            )
            slider(
                "Trim end",
                value: Binding(get: { model.trimEnd }, set: model.setTrimEnd),
                range: 0.1...model.recordingDuration,
                actionName: "Trim End"
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

            slider(
                "Padding",
                value: binding(\.canvas.padding, actionName: "Change Padding"),
                range: 0...160,
                actionName: "Change Padding"
            )
            slider(
                "Corners",
                value: binding(\.canvas.cornerRadius, actionName: "Change Corners"),
                range: 0...48,
                actionName: "Change Corners"
            )
            slider(
                "Shadow",
                value: binding(\.canvas.shadowRadius, actionName: "Change Shadow"),
                range: 0...60,
                actionName: "Change Shadow"
            )
        }
    }

    private var cursorSection: some View {
        editorSection("Cursor") {
            slider(
                "Size",
                value: binding(\.cursor.scale, actionName: "Change Cursor Size"),
                range: 0.75...2.5,
                actionName: "Change Cursor Size"
            )
            slider(
                "Smoothing",
                value: binding(\.cursor.smoothing, actionName: "Change Cursor Smoothing"),
                range: 0...1,
                actionName: "Change Cursor Smoothing"
            )
            slider(
                "Hide after",
                value: binding(\.cursor.hideAfter, actionName: "Change Cursor Visibility"),
                range: 0.5...5,
                actionName: "Change Cursor Visibility"
            )
            Toggle(
                "Click animation",
                isOn: binding(\.cursor.showsClickAnimation, actionName: "Toggle Click Animation")
            )
        }
    }

    private var zoomSection: some View {
        editorSection("Zooms") {
            Picker("Behavior", selection: zoomPresetBinding) {
                ForEach(ZoomBehaviorSettings.Preset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            Text(zoomPresetDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.zoomBehavior.preset == .custom {
                VStack(spacing: 10) {
                    slider(
                        "Intensity",
                        value: zoomBehaviorBinding(
                            \.scale,
                            actionName: "Change Zoom Intensity"
                        ),
                        range: 1.1...2.5,
                        actionName: "Change Zoom Intensity",
                        onEditingEnded: model.regenerateAutomaticZooms
                    )
                    slider(
                        "Transition",
                        value: zoomBehaviorBinding(
                            \.transitionDuration,
                            actionName: "Change Zoom Transition"
                        ),
                        range: 0.2...1.2,
                        actionName: "Change Zoom Transition",
                        onEditingEnded: model.regenerateAutomaticZooms
                    )
                    slider(
                        "Hold",
                        value: zoomBehaviorBinding(
                            \.holdDuration,
                            actionName: "Change Zoom Hold"
                        ),
                        range: 0.4...2.5,
                        actionName: "Change Zoom Hold",
                        onEditingEnded: model.regenerateAutomaticZooms
                    )
                    slider(
                        "Group clicks within",
                        value: zoomBehaviorBinding(
                            \.groupingInterval,
                            actionName: "Change Click Grouping"
                        ),
                        range: 0.5...3.5,
                        actionName: "Change Click Grouping",
                        onEditingEnded: model.regenerateAutomaticZooms
                    )
                }
                .padding(10)
                .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            if model.project.zoomSegments.isEmpty {
                Text(emptyZoomMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.project.zoomSegments.enumerated()), id: \.element.id) { index, zoom in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Button {
                                model.selectZoom(id: zoom.id)
                            } label: {
                                Label(
                                    timeLabel(zoom.startTime),
                                    systemImage: zoom.source == .automatic ? "wand.and.stars" : "hand.draw"
                                )
                                .font(.caption)
                            }
                            .buttonStyle(.plain)

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
                            range: 1.1...2.5,
                            actionName: "Change Zoom Scale"
                        )
                        slider(
                            "Focus X",
                            value: zoomBinding(index: index, keyPath: \.focusPoint.x),
                            range: 0...Double(model.project.recording.width),
                            actionName: "Change Zoom Focus"
                        )
                        slider(
                            "Focus Y",
                            value: zoomBinding(index: index, keyPath: \.focusPoint.y),
                            range: 0...Double(model.project.recording.height),
                            actionName: "Change Zoom Focus"
                        )
                        slider(
                            "Start",
                            value: zoomBinding(index: index, keyPath: \.startTime),
                            range: 0...model.recordingDuration,
                            actionName: "Change Zoom Start"
                        )
                        slider(
                            "End",
                            value: zoomBinding(index: index, keyPath: \.endTime),
                            range: 0...model.recordingDuration,
                            actionName: "Change Zoom End"
                        )
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                model.selectedZoomID == zoom.id ? Color.accentColor : .clear,
                                lineWidth: 2
                            )
                    }
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
        range: ClosedRange<Double>,
        actionName: String,
        onEditingEnded: (() -> Void)? = nil
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
            Slider(value: value, in: range) { isEditing in
                if isEditing {
                    model.beginHistoryTransaction(actionName: actionName)
                } else {
                    onEditingEnded?()
                    model.commitHistoryTransaction()
                }
            }
        }
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<RecordingProject, Value>,
        actionName: String
    ) -> Binding<Value> {
        Binding(
            get: { model.project[keyPath: keyPath] },
            set: { value in
                model.editProject(actionName: actionName) { project in
                    project[keyPath: keyPath] = value
                }
            }
        )
    }

    private func zoomScaleBinding(index: Int) -> Binding<Double> {
        Binding(
            get: { model.project.zoomSegments[index].scale },
            set: { value in
                model.editProject(actionName: "Change Zoom Scale") { project in
                    guard project.zoomSegments.indices.contains(index) else { return }
                    project.zoomSegments[index].scale = value
                }
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
                model.editProject(actionName: zoomActionName(keyPath)) { project in
                    guard project.zoomSegments.indices.contains(index) else { return }
                    if keyPath == \.startTime {
                        let latestStart = max(0, project.zoomSegments[index].endTime - 0.1)
                        project.zoomSegments[index].startTime = min(value, latestStart)
                        project.zoomSegments[index].focusTime = max(
                            project.zoomSegments[index].startTime,
                            project.zoomSegments[index].focusTime
                        )
                    } else if keyPath == \.endTime {
                        let earliestEnd = project.zoomSegments[index].startTime + 0.1
                        project.zoomSegments[index].endTime = max(value, earliestEnd)
                        project.zoomSegments[index].focusTime = min(
                            project.zoomSegments[index].endTime,
                            project.zoomSegments[index].focusTime
                        )
                    } else {
                        project.zoomSegments[index][keyPath: keyPath] = value
                    }
                }
            }
        )
    }

    private func zoomActionName(_ keyPath: WritableKeyPath<ZoomSegment, Double>) -> String {
        if keyPath == \.startTime { return "Change Zoom Start" }
        if keyPath == \.endTime { return "Change Zoom End" }
        return "Change Zoom Focus"
    }

    private var zoomPresetBinding: Binding<ZoomBehaviorSettings.Preset> {
        Binding(
            get: { model.zoomBehavior.preset },
            set: model.applyZoomPreset
        )
    }

    private func zoomBehaviorBinding(
        _ keyPath: WritableKeyPath<ZoomBehaviorSettings, Double>,
        actionName: String
    ) -> Binding<Double> {
        Binding(
            get: { model.zoomBehavior[keyPath: keyPath] },
            set: { value in
                model.updateCustomZoomBehavior(
                    keyPath,
                    value: value,
                    actionName: actionName
                )
            }
        )
    }

    private var zoomPresetDescription: String {
        switch model.zoomBehavior.preset {
        case .calm:
            return "Fewer, wider camera moves with slower transitions and longer holds."
        case .focused:
            return "Tighter framing that responds quickly to separate interactions."
        case .off:
            return "Automatic zooms are disabled. Manual zooms remain unchanged."
        case .custom:
            return "Tune automatic zoom intensity, timing, and click grouping."
        }
    }

    private var emptyZoomMessage: String {
        if model.zoomBehavior.preset == .off {
            return "Automatic zooms are off. Move the playhead and add one manually."
        }
        return "No clicks produced an automatic zoom. Move the playhead and add one manually."
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

    private func aspectFit(aspectRatio: Double, inside size: CGSize) -> CGSize {
        guard aspectRatio > 0, size.width > 0, size.height > 0 else { return size }
        if size.width / size.height > aspectRatio {
            return CGSize(width: size.height * aspectRatio, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspectRatio)
    }
}

private struct PreviewFocusOverlay: View {
    @ObservedObject var model: EditorModel
    let zoom: ZoomSegment
    @State private var pendingLocation: CGPoint?
    @State private var showsConfirmation = false

    var body: some View {
        GeometryReader { proxy in
            let canvas = CanvasGeometry(project: model.project, quality: model.quality)
            let mapper = PreviewFocusMapper(
                viewSize: proxy.size,
                canvasSize: canvas.canvasSize,
                screenRect: canvas.screenRect,
                sourceSize: CGSize(
                    width: model.project.recording.width,
                    height: model.project.recording.height
                ),
                cameraFocus: zoom.focusPoint.cgPoint,
                cameraScale: zoom.scale
            )
            let displayScale = mapper.displayedCanvasRect.width / max(1, canvas.canvasSize.width)
            let contentRect = CGRect(
                x: mapper.displayedCanvasRect.minX + canvas.screenRect.minX * displayScale,
                y: mapper.displayedCanvasRect.minY
                    + (canvas.canvasSize.height - canvas.screenRect.maxY) * displayScale,
                width: canvas.screenRect.width * displayScale,
                height: canvas.screenRect.height * displayScale
            )

            ZStack {
                Color.black.opacity(0.18)

                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: contentRect.width, height: contentRect.height)
                    .position(x: contentRect.midX, y: contentRect.midY)

                focusReticle
                    .position(x: contentRect.midX, y: contentRect.midY)

                if let pendingLocation {
                    pendingReticle
                        .position(pendingLocation)
                        .transition(.scale.combined(with: .opacity))
                }

                VStack {
                    Label(
                        showsConfirmation
                            ? "Focus updated for zoom at \(timeLabel(zoom.startTime))"
                            : "Editing zoom at \(timeLabel(zoom.startTime)) — click or drag to choose its center",
                        systemImage: showsConfirmation ? "checkmark.circle.fill" : "scope"
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(showsConfirmation ? Color.green : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard mapper.sourcePoint(for: value.location) != nil else { return }
                        pendingLocation = value.location
                        showsConfirmation = false
                    }
                    .onEnded { value in
                        guard let point = mapper.sourcePoint(for: value.location) else {
                            pendingLocation = nil
                            return
                        }
                        model.setSelectedZoomFocus(point)
                        if let selected = model.selectedZoom {
                            model.seek(to: selected.focusTime)
                        }
                        withAnimation(.easeOut(duration: 0.16)) {
                            pendingLocation = value.location
                            showsConfirmation = true
                        }
                    }
            )
        }
    }

    private var focusReticle: some View {
        ZStack {
            Circle()
                .stroke(.white, lineWidth: 2)
                .frame(width: 26, height: 26)
            Rectangle()
                .fill(.white)
                .frame(width: 1, height: 36)
            Rectangle()
                .fill(.white)
                .frame(width: 36, height: 1)
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
    }

    private var pendingReticle: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: 34, height: 34)
            Circle()
                .stroke(.white, lineWidth: 2)
                .frame(width: 20, height: 20)
            Circle()
                .fill(.white)
                .frame(width: 5, height: 5)
        }
        .shadow(color: .black.opacity(0.75), radius: 2)
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
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
