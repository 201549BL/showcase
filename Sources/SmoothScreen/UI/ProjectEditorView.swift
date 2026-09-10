import AVKit
import SwiftUI

struct ProjectEditorView: View {
    @ObservedObject var model: EditorModel
    let onClose: () -> Void
    @State private var isShowingExportOptions = false
    @State private var isEditingViewbox = false
    @State private var isShowingAdvancedZoomControls = false

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
                    isShowingExportOptions = true
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
        .sheet(isPresented: $isShowingExportOptions) {
            exportOptions
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
                isEditingViewbox = false
            }
        }
        .onChange(of: isEditingViewbox) {
            model.setViewboxEditing(isEditingViewbox)
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

    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Export video")
                .font(.title2.bold())
            Text("Export this project in any format. Choose another format to save another version.")
                .foregroundStyle(.secondary)
            Picker("Format", selection: binding(\.canvas.aspectRatio, actionName: "Change Format")) {
                ForEach(CanvasSettings.AspectRatio.allCases, id: \.self) { ratio in
                    Text(ratio.displayName).tag(ratio)
                }
            }
            Picker("Quality", selection: Binding(get: { model.quality }, set: model.setQuality)) {
                ForEach(ExportQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            Text("MP4 · \(model.exportDimensionsLabel)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { isShowingExportOptions = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export…") {
                    isShowingExportOptions = false
                    Task { await model.exportVideo() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            previewStage

            Divider()

            ZoomTimelineView(
                model: model,
                onEditCameraPosition: { isEditingViewbox = true }
            )
                .frame(height: model.hasAudio ? 153 : 112)
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
                    isEditingViewbox.toggle()
                    if isEditingViewbox, let target = model.selectedViewboxTarget {
                        model.seek(to: target.time)
                    }
                } label: {
                    Label(
                        isEditingViewbox ? "Done" : "Edit Framing",
                        systemImage: isEditingViewbox ? "checkmark.circle.fill" : "viewfinder"
                    )
                }
                .buttonStyle(.bordered)
                .tint(isEditingViewbox ? .accentColor : nil)
                .disabled(model.selectedZoom == nil)
                .help("Move and resize the visible area directly in the preview")

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

                    if
                        isEditingViewbox,
                        let target = model.selectedViewboxTarget
                    {
                        PreviewViewboxOverlay(model: model, target: target)
                            .id(target.id)
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
                if model.project.recording.cameraVideoRelativePath != nil {
                    cameraSection
                }
                motionSection
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
                    Text(ratio.displayName).tag(ratio)
                }
            }
            .pickerStyle(.menu)

            Text(model.exportDimensionsLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

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
                            .overlay {
                                if model.project.canvas.backgroundStartHex == preset.startHex
                                    && model.project.canvas.backgroundEndHex == preset.endHex {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .accessibilityLabel(preset.displayName)
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
            cursorSizeControl
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

    private var cursorSizeControl: some View {
        let scale = model.project.cursor.scale
        let scaleBinding = binding(\.cursor.scale, actionName: "Change Cursor Size")

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Cursor size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(scale.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            HStack(spacing: 8) {
                Button {
                    setCursorScale(scale - 0.1)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .help("Make cursor smaller")
                .disabled(scale <= 0.75)

                Slider(value: scaleBinding, in: 0.75...2.5, step: 0.05) { isEditing in
                    if isEditing {
                        model.beginHistoryTransaction(actionName: "Change Cursor Size")
                    } else {
                        model.commitHistoryTransaction()
                    }
                }
                .accessibilityLabel("Cursor size")

                Button {
                    setCursorScale(scale + 0.1)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Make cursor larger")
                .disabled(scale >= 2.5)
            }
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

            Picker("Camera motion", selection: zoomMotionStyleBinding) {
                ForEach(ZoomBehaviorSettings.MotionStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Text(zoomMotionStyleDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("Advanced automatic framing", isExpanded: $isShowingAdvancedZoomControls) {
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
            .disabled(model.zoomBehavior.preset == .off)

            Divider()

            if model.project.zoomSegments.isEmpty {
                Text(emptyZoomMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.project.zoomSegments) { zoom in
                    let positions = model.cameraPositions(for: zoom)
                    let isSelectedZoom = model.selectedZoomID == zoom.id

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Button {
                                model.selectBaseViewbox(for: zoom.id)
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

                        HStack {
                            Label(
                                zoom.source == .automatic
                                    ? "Smart cursor framing"
                                    : "Custom framing · follows near edges",
                                systemImage: "cursorarrow.motionlines"
                            )
                            Spacer()
                            Text("\(preciseTimeLabel(zoom.startTime))–\(preciseTimeLabel(zoom.endTime))")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Camera positions")
                                    .font(.caption.weight(.semibold))

                                Spacer()

                                Button {
                                    model.selectZoom(id: zoom.id, seekToFocus: false)
                                    if model.addCameraPositionAtPlayhead(to: zoom.id) != nil {
                                        isEditingViewbox = true
                                    }
                                } label: {
                                    Label("Add at Playhead", systemImage: "plus")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .disabled(!model.canAddCameraPosition(to: zoom.id))
                                .help("Add another camera position at the playhead")
                            }

                            ForEach(Array(positions.enumerated()), id: \.element.id) { index, position in
                                HStack {
                                    Button {
                                        model.selectCameraPosition(position, in: zoom.id)
                                        isEditingViewbox = true
                                    } label: {
                                        Label(
                                            "Position \(index + 1) · \(preciseTimeLabel(position.time))",
                                            systemImage: "diamond.fill"
                                        )
                                        .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(
                                        isSelectedZoom && model.selectedViewboxTarget?.id == position.id
                                            ? Color.accentColor
                                            : Color.primary
                                    )

                                    Spacer()

                                    if !position.isInitial {
                                        Button(role: .destructive) {
                                            model.deleteCameraPosition(id: position.id, from: zoom.id)
                                        } label: {
                                            Image(systemName: "xmark.circle")
                                        }
                                        .buttonStyle(.plain)
                                        .help("Delete this camera position")
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))

                        if isSelectedZoom, let target = model.selectedViewboxTarget {
                            slider(
                                "Position magnification · \(preciseTimeLabel(target.time))",
                                value: selectedCameraPositionScaleBinding(for: zoom),
                                range: 1.1...3.5,
                                actionName: "Change Camera Position Magnification"
                            )

                            Button {
                                model.seek(to: target.time)
                                isEditingViewbox = true
                            } label: {
                                Label("Edit Framing", systemImage: "viewfinder")
                            }
                            .buttonStyle(.bordered)
                        }

                        zoomCursorBoundaryControl(for: zoom)
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

    private var motionSection: some View {
        let amount = model.project.resolvedMotionBlur.amount

        return editorSection("Motion") {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Motion blur")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        amount == 0
                            ? "Off"
                            : amount.formatted(.percent.precision(.fractionLength(0)))
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                }

                Slider(value: motionBlurBinding, in: 0...1, step: 0.05) { isEditing in
                    if isEditing {
                        model.beginHistoryTransaction(actionName: "Change Motion Blur")
                    } else {
                        model.commitHistoryTransaction()
                    }
                }
                .accessibilityLabel("Motion blur")
            }

            Text("Adds blur only while the camera or cursor is moving.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cameraSection: some View {
        let settings = model.project.resolvedCameraOverlay

        return editorSection("Face camera") {
            Toggle(
                "Show camera",
                isOn: cameraOverlayBinding(
                    \.isVisible,
                    actionName: "Toggle Face Camera"
                )
            )

            Picker("Sizing", selection: cameraSizingModeBinding) {
                ForEach(CameraOverlaySettings.SizingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            slider(
                settings.resolvedSizingMode == .adaptive ? "Maximum size" : "Size",
                value: cameraOverlayBinding(
                    \.size,
                    actionName: "Change Face Camera Size"
                ),
                range: 0.12...0.4,
                actionName: "Change Face Camera Size"
            )

            Picker(
                "Position",
                selection: cameraOverlayBinding(
                    \.corner,
                    actionName: "Move Face Camera"
                )
            ) {
                Image(systemName: "arrow.up.left").tag(CameraOverlaySettings.Corner.topLeft)
                Image(systemName: "arrow.up.right").tag(CameraOverlaySettings.Corner.topRight)
                Image(systemName: "arrow.down.left").tag(CameraOverlaySettings.Corner.bottomLeft)
                Image(systemName: "arrow.down.right").tag(CameraOverlaySettings.Corner.bottomRight)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Face camera position")

            if settings.resolvedSizingMode == .adaptive {
                Text("Shrinks during close-ups and makes extra room when the cursor path approaches the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func setCursorScale(_ scale: Double) {
        let clampedScale = min(2.5, max(0.75, scale))
        model.editProject(actionName: "Change Cursor Size") { project in
            project.cursor.scale = clampedScale
        }
    }

    private func selectedCameraPositionScaleBinding(for zoom: ZoomSegment) -> Binding<Double> {
        return Binding(
            get: {
                guard model.selectedZoomID == zoom.id else {
                    return model.project.zoomSegments
                        .first(where: { $0.id == zoom.id })?
                        .scale ?? zoom.scale
                }
                return model.selectedViewboxTarget?.scale ?? zoom.scale
            },
            set: { value in
                guard
                    model.selectedZoomID == zoom.id,
                    let target = model.selectedViewboxTarget
                else { return }
                model.setSelectedZoomViewbox(
                    focusPoint: target.focusPoint,
                    scale: value
                )
            }
        )
    }

    private func zoomCursorBoundaryControl(for zoom: ZoomSegment) -> some View {
        let reference = ZoomSegmentBindingReference(fallback: zoom)
        let value = Binding(
            get: {
                model.project.zoomSegments
                    .first(where: { $0.id == zoom.id })?
                    .resolvedCursorBoundaryFraction
                    ?? zoom.resolvedCursorBoundaryFraction
            },
            set: { value in
                model.editProject(actionName: "Change Cursor Boundary") { project in
                    guard let index = reference.index(in: project.zoomSegments) else { return }
                    project.zoomSegments[index].cursorBoundaryFraction = min(
                        ZoomSegment.cursorBoundaryRange.upperBound,
                        max(ZoomSegment.cursorBoundaryRange.lowerBound, value)
                    )
                }
            }
        )

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Cursor boundary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Slider(
                value: value,
                in: ZoomSegment.cursorBoundaryRange,
                step: 0.05
            ) { isEditing in
                if isEditing {
                    model.beginHistoryTransaction(actionName: "Change Cursor Boundary")
                } else {
                    model.commitHistoryTransaction()
                }
            }
            .help("Smaller values keep the cursor nearer the center; larger values allow more movement before the camera follows")
        }
    }

    private var zoomPresetBinding: Binding<ZoomBehaviorSettings.Preset> {
        Binding(
            get: { model.zoomBehavior.preset },
            set: model.applyZoomPreset
        )
    }

    private var zoomMotionStyleBinding: Binding<ZoomBehaviorSettings.MotionStyle> {
        Binding(
            get: { model.zoomBehavior.resolvedMotionStyle },
            set: model.setZoomMotionStyle
        )
    }

    private var motionBlurBinding: Binding<Double> {
        Binding(
            get: { model.project.resolvedMotionBlur.amount },
            set: { amount in
                model.editProject(actionName: "Change Motion Blur") { project in
                    project.motionBlur = MotionBlurSettings(
                        amount: min(1, max(0, amount))
                    )
                }
            }
        )
    }

    private var cameraSizingModeBinding: Binding<CameraOverlaySettings.SizingMode> {
        Binding(
            get: { model.project.resolvedCameraOverlay.resolvedSizingMode },
            set: { mode in
                model.editProject(actionName: "Change Face Camera Sizing") { project in
                    var settings = project.resolvedCameraOverlay
                    settings.sizingMode = mode
                    project.cameraOverlay = settings
                }
            }
        )
    }

    private func cameraOverlayBinding<Value>(
        _ keyPath: WritableKeyPath<CameraOverlaySettings, Value>,
        actionName: String
    ) -> Binding<Value> {
        Binding(
            get: { model.project.resolvedCameraOverlay[keyPath: keyPath] },
            set: { value in
                model.editProject(actionName: actionName) { project in
                    var settings = project.resolvedCameraOverlay
                    settings[keyPath: keyPath] = value
                    project.cameraOverlay = settings
                }
            }
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
            return "Adapts framing to each interaction and resets between distinct shots."
        case .focused:
            return "Strong close-ups for dense interfaces and small controls."
        case .off:
            return "Automatic zooms are disabled. Manual zooms remain unchanged."
        case .custom:
            return "Tune automatic zoom intensity, timing, and click grouping."
        }
    }

    private var zoomMotionStyleDescription: String {
        switch model.zoomBehavior.resolvedMotionStyle {
        case .focused:
            return "Settles quickly so text and controls remain easy to follow."
        case .smooth:
            return "Uses slower, more fluid camera moves for visual demos."
        }
    }

    private var emptyZoomMessage: String {
        if model.zoomBehavior.preset == .off {
            return "Automatic zooms are off. Move the playhead and add one manually."
        }
        return "No clicks produced an automatic zoom. Move the playhead and add one manually."
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func preciseTimeLabel(_ seconds: Double) -> String {
        String(
            format: "%02d:%04.1f",
            Int(seconds) / 60,
            seconds.truncatingRemainder(dividingBy: 60)
        )
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

struct ZoomSegmentBindingReference {
    let fallback: ZoomSegment

    func value(
        in segments: [ZoomSegment],
        keyPath: KeyPath<ZoomSegment, Double>
    ) -> Double {
        segments.first(where: { $0.id == fallback.id })?[keyPath: keyPath]
            ?? fallback[keyPath: keyPath]
    }

    func index(in segments: [ZoomSegment]) -> Int? {
        segments.firstIndex(where: { $0.id == fallback.id })
    }
}

private struct PreviewViewboxOverlay: View {
    private enum Handle: CaseIterable, Identifiable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var id: Self { self }

        func position(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    @ObservedObject var model: EditorModel
    let target: ZoomViewboxEditTarget
    @State private var pendingFocus: CGPoint?
    @State private var pendingScale: Double?
    @State private var showsConfirmation = false

    private let coordinateSpaceName = "zoomViewboxEditor"
    private let scaleRange = 1.1...3.5

    var body: some View {
        GeometryReader { proxy in
            let canvas = CanvasGeometry(project: model.project, quality: model.quality)
            let mapper = PreviewViewboxMapper(
                viewSize: proxy.size,
                canvasSize: canvas.canvasSize,
                screenRect: canvas.screenRect,
                sourceSize: CGSize(
                    width: model.project.recording.width,
                    height: model.project.recording.height
                )
            )
            let focus = pendingFocus ?? target.focusPoint
            let scale = pendingScale ?? target.scale
            let viewboxRect = mapper.viewboxRect(
                focusPoint: focus,
                scale: scale
            )

            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRoundedRect(
                        in: viewboxRect,
                        cornerSize: CGSize(width: 8, height: 8)
                    )
                }
                .fill(Color.black.opacity(0.52), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.001))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white, lineWidth: 2)
                            .shadow(color: .black.opacity(0.8), radius: 2)
                    }
                    .overlay {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .frame(width: viewboxRect.width, height: viewboxRect.height)
                    .position(x: viewboxRect.midX, y: viewboxRect.midY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(mapper: mapper, scale: scale))

                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        Color.accentColor.opacity(0.9),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                    .frame(
                        width: viewboxRect.width * target.cursorBoundaryFraction,
                        height: viewboxRect.height * target.cursorBoundaryFraction
                    )
                    .position(x: viewboxRect.midX, y: viewboxRect.midY)
                    .allowsHitTesting(false)

                ForEach(Handle.allCases) { handle in
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .padding(8)
                        .contentShape(Rectangle())
                        .gesture(resizeGesture(mapper: mapper))
                        .position(handle.position(in: viewboxRect))
                }

                VStack {
                    Label(
                        showsConfirmation
                            ? "Framing updated at \(timeLabel(target.time))"
                            : "Cursor moves freely inside the dashed area · \(scale.formatted(.number.precision(.fractionLength(2))))×",
                        systemImage: showsConfirmation ? "checkmark.circle.fill" : "viewfinder"
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
            .coordinateSpace(name: coordinateSpaceName)
        }
    }

    private func moveGesture(
        mapper: PreviewViewboxMapper,
        scale: Double
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                pendingFocus = mapper.focusPoint(
                    moving: target.focusPoint,
                    by: value.translation,
                    scale: scale
                )
                showsConfirmation = false
            }
            .onEnded { _ in
                commit(focusPoint: pendingFocus ?? target.focusPoint, scale: scale)
            }
    }

    private func resizeGesture(mapper: PreviewViewboxMapper) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                let scale = mapper.scale(
                    resizingHandleTo: value.location,
                    focusPoint: target.focusPoint,
                    initialScale: target.scale,
                    allowedRange: scaleRange
                )
                pendingScale = scale
                pendingFocus = mapper.clampedFocusPoint(
                    target.focusPoint,
                    scale: scale
                )
                showsConfirmation = false
            }
            .onEnded { _ in
                commit(
                    focusPoint: pendingFocus ?? target.focusPoint,
                    scale: pendingScale ?? target.scale
                )
            }
    }

    private func commit(focusPoint: CGPoint, scale: Double) {
        model.setSelectedZoomViewbox(focusPoint: focusPoint, scale: scale)
        if let selected = model.selectedViewboxTarget {
            model.seek(to: selected.time)
        }
        pendingFocus = nil
        pendingScale = nil
        withAnimation(.easeOut(duration: 0.16)) {
            showsConfirmation = true
        }
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
