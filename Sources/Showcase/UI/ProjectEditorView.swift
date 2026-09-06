import AVKit
import SwiftUI

struct ProjectEditorView: View {
    @ObservedObject var model: EditorModel
    let onClose: () -> Void
    @State private var category = "Frame"
    @State private var showingWallpapers = false
    @State private var showingExport = false
    @State private var sidebarWidth: CGFloat = 310
    @State private var sidebarResizeStart: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let maximumSidebarWidth = min(360, max(280, proxy.size.width - 598))
                let width = min(sidebarWidth, maximumSidebarWidth)
                HStack(spacing: 0) {
                    previewStage.frame(minWidth: 550, maxWidth: .infinity)
                        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 16)
                    // Keep the resize target without the native split view's dark rule.
                    Color.clear.frame(width: 8)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(coordinateSpace: .named("editor-panes"))
                            .onChanged { value in
                                if sidebarResizeStart == nil { sidebarResizeStart = width }
                                sidebarWidth = min(maximumSidebarWidth,
                                                   max(280, (sidebarResizeStart ?? width) - value.translation.width))
                            }
                            .onEnded { _ in sidebarResizeStart = nil })
                        .help("Drag to resize the sidebar")
                        .accessibilityLabel("Sidebar width")
                        .accessibilityValue("\(Int(width)) points")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: sidebarWidth = min(maximumSidebarWidth, width + 10)
                            case .decrement: sidebarWidth = max(280, width - 10)
                            @unknown default: break
                            }
                        }
                    controlsPane.frame(width: width)
                        .padding(.trailing, 16).padding(.vertical, 16)
                }
                .coordinateSpace(name: "editor-panes")
            }
            timelinePane
        }
        .sheet(isPresented: $showingWallpapers) {
            DesktopWallpaperPicker { wallpaper in
                model.applyBackgroundImage(at: wallpaper.url, name: wallpaper.name)
            }
        }
        .onAppear { model.selectedZoomID = nil; model.selectedCameraID = nil }
        .background(EditorPlaybackShortcuts(model: model))
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
                Menu {
                    Button("Show Project in Finder") { model.revealProject() }
                    if model.lastExportURL != nil {
                        Button("Show Last Export in Finder") { model.revealLastExport() }
                    }
                } label: { Image(systemName: "ellipsis") }
                .help("Project actions")

                Button {
                    showingExport = true
                } label: {
                    if model.isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .appGlassButton(prominent: true)
                .disabled(model.isExporting)
                .popover(isPresented: $showingExport) { exportPanel }
            }
        }
        .alert(item: $model.presentedError) { error in
            Alert(
                title: Text("Showcase couldn’t continue"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
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

    private var timelinePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Timeline").font(.headline)
                Text("\(model.project.zoomSegments.count) zooms")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: model.resetTrim) {
                    Label("Reset trim", systemImage: "arrow.uturn.backward")
                }
                .appGlassButton()
                .disabled(!model.isTrimmed)
                .help("Restore the full recording")
                Menu {
                    Button(action: model.addManualZoom) {
                        Label("Screen zoom", systemImage: "plus.magnifyingglass")
                    }
                    Button(action: model.addCameraEmphasis) {
                        Label("Camera effect", systemImage: "sparkles")
                    }.disabled(!model.canAddCameraEmphasis)
                } label: {
                    Label("Add effect", systemImage: "plus")
                }
                .appGlassButton()
                .help("Add a screen zoom or camera effect at the playhead")
            }
            .frame(minHeight: 32)
            .overlay { playbackControls }
            .padding(.horizontal, 16).padding(.top, 14)
            ZoomTimelineView(model: model)
                .frame(height: 182 + model.cameraTimelineExtraHeight)
        }
        .appGlassSurface(in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Button(action: model.jumpToStart) {
                Image(systemName: "backward.end.fill").frame(width: 16, height: 16)
            }
            .appGlassButton()
            .accessibilityLabel("Jump to start")
            .help("Jump to start")

            Button(action: model.togglePlayback) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16, height: 16)
            }
            .appGlassButton()
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")

            Text("\(preciseTimeLabel(model.playheadTime)) / \(preciseTimeLabel(model.trimEnd))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("Playback time")
                .accessibilityValue("\(preciseTimeLabel(model.playheadTime)) of \(preciseTimeLabel(model.trimEnd))")
        }
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export video").font(.headline)
            Picker("Resolution", selection: Binding(get: { model.quality }, set: model.setQuality)) {
                ForEach(ExportQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            Text("MP4 · \(aspectName(model.project.canvas.aspectRatio)) · \(preciseTimeLabel(model.trimEnd - model.trimStart))")
                .font(.caption).foregroundStyle(.secondary)
            Button("Choose location & export…") {
                showingExport = false
                Task { await model.exportVideo() }
            }.appGlassButton(prominent: true)
        }.padding(22).frame(width: 310)
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
                EditorVideoView(player: model.player)
                    .frame(width: previewSize.width, height: previewSize.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minHeight: 260)
    }

    private var sidebarGlassTint: Color {
        Color(hex: model.project.canvas.backgroundStartHex).opacity(0.07)
    }

    private var controlsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarTabs(
                selection: model.selectedZoom == nil && model.selectedCamera == nil && model.selectedCameraEmphasis == nil ? category : nil,
                showsCamera: model.project.recording.cameraVideoRelativePath != nil,
                tint: sidebarGlassTint
            ) { selection in
                category = selection
                model.selectedZoomID = nil
                model.selectedCameraID = nil
                model.selectedCameraEmphasisID = nil
            }
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let zoom = model.selectedZoom {
                        selectedZoomInspector(zoom)
                    } else if let effect = model.selectedCameraEmphasis {
                        CameraEmphasisInspector(model: model, effect: effect)
                    } else if let camera = model.selectedCamera {
                        selectedCameraInspector(camera)
                    } else {
                        switch category {
                        case "Cursor": cursorSection
                        case "Motion": zoomSection
                        case "Camera":
                            cameraEmphasisAction
                            cameraSection
                            cameraSectionsList
                        default: styleSection
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(model.selectedZoomID?.uuidString ?? model.selectedCameraID?.uuidString ?? model.selectedCameraEmphasisID?.uuidString ?? category)
            }
            .appGlassSurface(in: RoundedRectangle(cornerRadius: 24), tint: sidebarGlassTint)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func selectedZoomInspector(_ zoom: ZoomSegment) -> some View {
        let index = (model.project.zoomSegments.firstIndex(where: { $0.id == zoom.id }) ?? 0) + 1
        return VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Zoom \(index)").font(.title3.weight(.semibold))
                Spacer()
                Text(zoom.source == .automatic ? "Automatic" : "Manual")
                    .font(.caption).foregroundStyle(.secondary)
            }
            slider("Magnification", value: zoomScaleBinding(for: zoom), range: 1.1...3.5,
                   actionName: "Change Zoom Magnification", unit: .magnification)
            Divider()
            HStack(spacing: 12) {
                zoomTimeField("Start", zoom: zoom, start: true)
                zoomTimeField("End", zoom: zoom, start: false)
            }
            HStack {
                Text("Duration")
                Spacer()
                Text("\((zoom.endTime - zoom.startTime).formatted(.number.precision(.fractionLength(1)))) s")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            Divider()
            Button(role: .destructive) { model.deleteZoom(id: zoom.id) } label: {
                Label("Delete zoom", systemImage: "trash")
            }.buttonStyle(.borderless)
        }
    }

    private var cameraEmphasisAction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: model.addCameraEmphasis) {
                Label("Add camera effect", systemImage: "sparkles")
            }.appGlassButton().disabled(!model.canAddCameraEmphasis)
            Text(model.canAddCameraEmphasis
                 ? "Animate camera size at the playhead."
                 : "Place the playhead in a visible camera clip, outside an existing emphasis.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cameraSectionsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Visibility").font(.callout.weight(.medium))
            Text("Camera clips control when the camera is visible. Gaps hide it.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(model.project.resolvedCameraSegments.enumerated()), id: \.element.id) { index, section in
                Button { model.selectCamera(id: section.id) } label: {
                    HStack {
                        Text("Camera \(index + 1)")
                        Spacer()
                        Text("\(preciseTimeLabel(section.startTime))–\(preciseTimeLabel(section.endTime))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }.font(.caption)
                }.buttonStyle(.plain)
            }
            Button(action: model.addCameraSection) {
                Label("Add section at playhead", systemImage: "plus")
            }.appGlassButton().disabled(!model.canAddCamera)
        }
    }

    private func selectedCameraInspector(_ camera: CameraSegment) -> some View {
        let index = (model.project.resolvedCameraSegments.firstIndex { $0.id == camera.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Camera \(index)", systemImage: "video").font(.title3.weight(.semibold))
                Spacer()
                Text("\((camera.endTime - camera.startTime).formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                cameraTimeField("Start", camera: camera, edge: .start)
                cameraTimeField("End", camera: camera, edge: .end)
            }
            Text("Camera is visible during this clip.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            cameraEmphasisAction
            Button("Camera appearance…") {
                model.selectedCameraID = nil
                category = "Camera"
            }.buttonStyle(.borderless)
            if camera.settings != nil {
                Text("This clip retains custom appearance settings from an earlier edit.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use camera defaults") {
                    model.editProject(actionName: "Reset Camera Clip Appearance") { project in
                        var clips = project.resolvedCameraSegments
                        guard let index = clips.firstIndex(where: { $0.id == camera.id }) else { return }
                        clips[index].settings = nil
                        project.cameraSegments = clips
                    }
                }.buttonStyle(.borderless)
            }
            Divider()
            HStack {
                Button(action: model.splitCameraSection) {
                    Label("Split at playhead", systemImage: "scissors")
                }.appGlassButton().disabled(!model.canSplitCamera)
                Spacer(minLength: 4)
                Button(role: .destructive) { model.deleteCameraSection(id: camera.id) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless).help("Delete camera section")
                    .accessibilityLabel("Delete camera section")
            }
        }
    }

    private func cameraTimeField(_ title: String, camera: CameraSegment,
                                 edge: EditorModel.CameraTimingEdit) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: {
                let current = model.project.resolvedCameraSegments.first { $0.id == camera.id } ?? camera
                return edge == .start ? current.startTime : current.endTime
            }, set: { value in
                guard value.isFinite else { return }
                model.beginHistoryTransaction(actionName: "Resize Camera Section")
                model.updateCameraTiming(id: camera.id, to: value, edge: edge)
                model.commitTimelineEdit()
            }), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder).monospacedDigit()
            .accessibilityLabel("Camera \(title.lowercased()) in seconds")
        }
    }

    private func zoomTimeField(_ title: String, zoom: ZoomSegment, start: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(
                get: {
                    let current = model.project.zoomSegments.first(where: { $0.id == zoom.id }) ?? zoom
                    return start ? current.startTime : current.endTime
                },
                set: { value in
                    guard value.isFinite else { return }
                    model.beginHistoryTransaction(actionName: "Resize Zoom")
                    if start { model.resizeZoomStart(id: zoom.id, to: value) }
                    else { model.resizeZoomEnd(id: zoom.id, to: value) }
                    model.commitTimelineEdit()
                }
            ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder).monospacedDigit()
            .accessibilityLabel("Zoom \(title.lowercased()) in seconds")
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aspect ratio").font(.callout)
                Picker("Aspect ratio", selection: binding(\.canvas.aspectRatio, actionName: "Change Format")) {
                    ForEach(CanvasSettings.AspectRatio.allCases, id: \.self) { ratio in
                        Text(aspectName(ratio)).tag(ratio)
                    }
                }.pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Background").font(.callout)
                HStack(spacing: 12) {
                    ForEach(BackgroundPreset.allCases) { preset in
                        Button { model.applyBackground(preset) } label: {
                            Circle().fill(backgroundGradient(preset)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.white.opacity(0.4)))
                                .overlay {
                                    if isSelectedBackground(preset) {
                                        Circle().stroke(.primary.opacity(0.8), lineWidth: 2).padding(-4)
                                    }
                                }
                        }.buttonStyle(.plain).help(preset.displayName)
                            .accessibilityLabel(preset.displayName)
                            .accessibilityAddTraits(isSelectedBackground(preset) ? [.isSelected] : [])
                    }
                }
                HStack(spacing: 8) {
                    Button(action: model.chooseBackgroundImage) {
                        Label("Choose image…", systemImage: "photo.badge.plus")
                    }
                    Button { showingWallpapers = true } label: {
                        Label("Desktop…", systemImage: "desktopcomputer")
                    }
                }
                .controlSize(.small)
                if let asset = model.project.canvas.backgroundImage,
                   let url = model.backgroundImageURL {
                    HStack(spacing: 10) {
                        BackgroundImageThumbnail(url: url)
                        Text(asset.name).font(.callout).lineLimit(2)
                        Spacer(minLength: 0)
                        Button {
                            model.editProject(actionName: "Remove Background Image") { $0.canvas.backgroundImage = nil }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Remove image background")
                        .accessibilityLabel("Remove image background")
                    }
                }
            }
            slider("Padding", value: binding(\.canvas.padding, actionName: "Change Padding"),
                   range: 0...160, actionName: "Change Padding", unit: .pixels)
            slider("Corner radius", value: binding(\.canvas.cornerRadius, actionName: "Change Corners"),
                   range: 0...48, actionName: "Change Corners", unit: .pixels)
            slider("Shadow", value: binding(\.canvas.shadowRadius, actionName: "Change Shadow"),
                   range: 0...60, actionName: "Change Shadow", unit: .pixels)
        }
    }

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            slider("Size", value: binding(\.cursor.scale, actionName: "Change Cursor Size"),
                   range: 0.75...2.5, actionName: "Change Cursor Size", unit: .percent)
            slider("Smoothing", value: binding(\.cursor.smoothing, actionName: "Change Cursor Smoothing"),
                   range: 0...1, actionName: "Change Cursor Smoothing", unit: .percent)
            Toggle("Click animation", isOn: binding(\.cursor.showsClickAnimation, actionName: "Toggle Click Animation"))
                .toggleStyle(.switch)
            slider("Hide after inactivity", value: binding(\.cursor.hideAfter, actionName: "Change Cursor Visibility"),
                   range: 0.5...5, actionName: "Change Cursor Visibility", unit: .seconds)
        }
    }

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Movement").font(.callout.weight(.semibold))
                Picker("Movement style", selection: zoomMotionStyleBinding) {
                    ForEach(ZoomBehaviorSettings.MotionStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                slider("Motion blur", value: motionBlurBinding, range: 0...1,
                       actionName: "Change Motion Blur", unit: .percent)
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Automatic zooms").font(.callout.weight(.semibold))
                    Spacer()
                    if model.zoomBehavior.preset == .custom {
                        Text("Custom").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Automatic zoom behavior", selection: zoomPresetBinding) {
                    Text("Off").tag(Optional(ZoomBehaviorSettings.Preset.off))
                    Text("Smart").tag(Optional(ZoomBehaviorSettings.Preset.calm))
                    Text("Close-up").tag(Optional(ZoomBehaviorSettings.Preset.focused))
                }.pickerStyle(.segmented).labelsHidden()
                VStack(spacing: 18) {
                    slider("Magnification", value: zoomBehaviorBinding(\.scale, actionName: "Change Zoom Magnification"),
                           range: 1.1...2.5, actionName: "Change Zoom Magnification", unit: .magnification,
                           onEditingEnded: model.regenerateAutomaticZooms)
                    slider("Transition duration", value: zoomBehaviorBinding(\.transitionDuration, actionName: "Change Zoom Transition"),
                           range: 0.2...1.2, actionName: "Change Zoom Transition", unit: .seconds,
                           onEditingEnded: model.regenerateAutomaticZooms)
                    slider("Hold after click", value: zoomBehaviorBinding(\.holdDuration, actionName: "Change Zoom Hold"),
                           range: 0.4...2.5, actionName: "Change Zoom Hold", unit: .seconds,
                           onEditingEnded: model.regenerateAutomaticZooms)
                    slider("Click grouping interval", value: zoomBehaviorBinding(\.groupingInterval, actionName: "Change Click Grouping"),
                           range: 0.5...3.5, actionName: "Change Click Grouping", unit: .seconds,
                           onEditingEnded: model.regenerateAutomaticZooms)
                }
                .disabled(model.zoomBehavior.preset == .off)

                Button("Reset automatic zooms", action: model.regenerateAutomaticZooms)
                    .buttonStyle(.borderless).font(.callout)
                    .disabled(model.zoomBehavior.preset == .off)
                    .help("Rebuild automatic zooms using these settings. Manual zooms are kept.")
            }
        }
    }

    private var cameraSection: some View {
        let settings = model.cameraInspectorSettings
        return VStack(alignment: .leading, spacing: 14) {
            if model.selectedCamera != nil && !model.project.resolvedCameraOverlay.isVisible {
                Text("Camera is hidden for this recording.").font(.caption).foregroundStyle(.secondary)
                Button("Enable camera") {
                    model.editProject(actionName: "Enable Camera") { project in
                        var settings = project.resolvedCameraOverlay
                        settings.isVisible = true
                        project.cameraOverlay = settings
                    }
                }.appGlassButton()
            }
            Toggle(model.selectedCamera == nil ? "Show camera" : "Show in this section", isOn: cameraOverlayBinding(\.isVisible, actionName: "Toggle Face Camera"))
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Mirror camera", isOn: Binding(
                    get: { model.cameraInspectorSettings.resolvedIsMirrored },
                    set: { mirrored in
                        model.editCameraSettings(actionName: "Mirror Camera", updateClipOverrides: true) { $0.isMirrored = mirrored }
                    }
                ))
                .toggleStyle(.switch)
                .help("Flip the camera image horizontally")
                HStack {
                    Text("Position").font(.callout)
                    Spacer()
                    Picker("Position", selection: cameraOverlayBinding(\.corner, actionName: "Move Face Camera")) {
                        Label("Top left", systemImage: "arrow.up.left").tag(CameraOverlaySettings.Corner.topLeft)
                        Label("Top right", systemImage: "arrow.up.right").tag(CameraOverlaySettings.Corner.topRight)
                        Label("Bottom left", systemImage: "arrow.down.left").tag(CameraOverlaySettings.Corner.bottomLeft)
                        Label("Bottom right", systemImage: "arrow.down.right").tag(CameraOverlaySettings.Corner.bottomRight)
                    }.pickerStyle(.segmented).labelStyle(.iconOnly).labelsHidden()
                }
                slider("Normal size", value: cameraOverlayBinding(\.size, actionName: "Change Face Camera Size"),
                       range: 0.12...0.4, actionName: "Change Face Camera Size", unit: .percent)
                if settings.resolvedSizingMode == .adaptive && model.selectedCamera == nil {
                    Text("Size effects are added during screen zooms. Select an effect in the timeline to adjust its size and timing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(!settings.isVisible)
            Button("Generate camera effects", action: model.useRecommendedCameraBehavior)
                .buttonStyle(.borderless).font(.caption)
                .help("Add smaller camera sizes during screen zooms. Keeps your edited effects.")
        }
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        actionName: String,
        unit: EditorSlider.Unit = .seconds,
        onEditingEnded: (() -> Void)? = nil
    ) -> some View {
        EditorSlider(title: title, value: value, range: range, unit: unit,
                     beginEditing: { model.beginHistoryTransaction(actionName: actionName) },
                     endEditing: {
                         onEditingEnded?()
                         model.commitHistoryTransaction()
                     })
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

    private func zoomScaleBinding(for zoom: ZoomSegment) -> Binding<Double> {
        let reference = ZoomSegmentBindingReference(fallback: zoom)
        return Binding(
            get: { reference.value(in: model.project.zoomSegments, keyPath: \.scale) },
            set: { value in
                model.editProject(actionName: "Change Zoom Magnification") { project in
                    guard let index = reference.index(in: project.zoomSegments) else { return }
                    project.zoomSegments[index].scale = min(3.5, max(1.1, value))
                }
            }
        )
    }

    private var zoomPresetBinding: Binding<ZoomBehaviorSettings.Preset?> {
        Binding(
            get: { model.zoomBehavior.preset == .custom ? nil : model.zoomBehavior.preset },
            set: { if let preset = $0 { model.applyZoomPreset(preset) } }
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

    private func cameraOverlayBinding<Value>(
        _ keyPath: WritableKeyPath<CameraOverlaySettings, Value>,
        actionName: String
    ) -> Binding<Value> {
        Binding(
            get: { model.cameraInspectorSettings[keyPath: keyPath] },
            set: { value in
                model.editCameraSettings(actionName: actionName, updateClipOverrides: keyPath != \CameraOverlaySettings.isVisible) { $0[keyPath: keyPath] = value }
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

    private func aspectName(_ ratio: CanvasSettings.AspectRatio) -> String {
        switch ratio {
        case .source: return "Source"
        case .landscape: return "16:9"
        case .square: return "1:1"
        case .vertical: return "9:16"
        }
    }

    private func preciseTimeLabel(_ seconds: Double) -> String {
        String(
            format: "%02d:%04.1f",
            Int(seconds) / 60,
            seconds.truncatingRemainder(dividingBy: 60)
        )
    }

    private func isSelectedBackground(_ preset: BackgroundPreset) -> Bool {
        model.project.canvas.backgroundImage == nil
            && model.project.canvas.backgroundStartHex == preset.startHex
            && model.project.canvas.backgroundEndHex == preset.endHex
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

private struct BackgroundImageThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 60, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: url) {
            image = BackgroundImages.image(at: url, maximumDimension: 160)
                .map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}
