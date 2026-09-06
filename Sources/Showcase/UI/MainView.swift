import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let editor = model.editor {
                ProjectEditorView(model: editor) { model.closeEditor() }
                    .frame(minWidth: 940, minHeight: 660)
            } else if model.isRecording {
                RecordingStrip(model: model)
                    .frame(width: 360, height: 96)
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                RecordingSetupView(model: model, devices: model.devicePreview)
                    .frame(width: 520, height: 88)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .background(RecordingWindowBridge(model: model))
        .task {
            if model.editor == nil { await model.refreshSources() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.editor == nil { Task { await model.refreshSources() } }
        }
        .alert(item: $model.presentedError) { error in
            Alert(title: Text("Showcase couldn’t continue"), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
    }
}

private struct RecordingSetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var devices: CaptureDevicePreview
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var popover: InputPopover?

    private enum InputPopover: String, Identifiable {
        case source, microphone, audio, camera
        var id: String { rawValue }
        var title: String {
            switch self {
            case .source: return "Record"
            case .microphone: return "Microphone"
            case .audio: return "System audio"
            case .camera: return "Camera"
            }
        }
    }

    private var isBusy: Bool { model.countdownRemaining != nil || model.isStartingOrStopping }
    private var needsPermission: Bool { !model.hasScreenRecordingPermission || !model.hasInputMonitoringPermission }
    private var previewConfiguration: String {
        "\(isBusy)-\(popover?.rawValue ?? "none")-\(model.includesCamera)-\(model.includesMicrophone)-\(model.selectedCameraID ?? "default")-\(model.selectedMicrophoneID ?? "default")"
    }

    var body: some View {
        Group {
            if let remaining = model.countdownRemaining {
                HStack(spacing: 22) {
                    Text("Get ready").foregroundStyle(.secondary)
                    Text("\(remaining)").font(.system(size: 24, weight: .medium, design: .rounded))
                        .monospacedDigit().frame(width: 24)
                    Button("Cancel") { model.cancelRecordingCountdown() }
                        .appGlassButton().keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 18).frame(height: 64)
                .appGlassSurface(in: Capsule())
            } else {
                bar
            }
        }
        .padding(12)
        .popover(item: $popover, arrowEdge: .top) { item in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(item.title).font(.headline)
                    Spacer()
                    Button { popover = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close \(item.title)")
                }
                if item == .source {
                    RecordingSourcePicker(model: model) { popover = nil }
                } else {
                    devicePopover(item)
                }
            }
            .padding(22).frame(width: item == .source ? 380 : 290)
            .background(RecordingPopoverFocusBridge())
        }
        .onChange(of: isBusy) { if isBusy { popover = nil } }
        .task(id: previewConfiguration) {
            if isBusy || popover == nil {
                await devices.stop()
            } else {
                await devices.update(
                    cameraEnabled: popover == .camera && model.includesCamera, cameraID: model.selectedCameraID,
                    microphoneEnabled: popover == .microphone && model.includesMicrophone, microphoneID: model.selectedMicrophoneID
                )
            }
        }
        .onDisappear {
            model.cancelRecordingCountdown()
            Task { await devices.stop() }
        }
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Button { popover = .source } label: {
                HStack(spacing: 9) {
                    Image(systemName: needsPermission ? "lock.shield" : model.selectedSource?.descriptor.kind == .window ? "macwindow" : "display")
                        .font(.system(size: 17))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(needsPermission ? "Allow access" : model.selectedSource?.descriptor.displayName ?? "Choose source")
                            .font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(needsPermission ? "Setup required" : model.selectedSource?.descriptor.kind == .window ? "Window" : "Entire screen")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }.frame(width: 132, height: 44)
            }
            .buttonStyle(RecorderControlStyle())
            .accessibilityLabel("Choose screen or window")
            .accessibilityValue(model.selectedSource?.descriptor.displayName ?? "No source")
            separator
            deviceButton(.microphone, icon: model.includesMicrophone ? "mic" : "mic.slash", enabled: model.includesMicrophone)
            deviceButton(.audio, icon: model.includesSystemAudio ? "speaker.wave.2" : "speaker.slash", enabled: model.includesSystemAudio)
            deviceButton(.camera, icon: model.includesCamera ? "video" : "video.slash", enabled: model.includesCamera)
            separator
            Button { Task { await model.beginRecordingCountdown() } } label: {
                HStack(spacing: 7) {
                    if model.isStartingOrStopping { ProgressView().controlSize(.small) }
                    else { Circle().fill(.white).frame(width: 9, height: 9) }
                    Text(model.isStartingOrStopping ? "Wait…" : "Record").font(.system(size: 13, weight: .medium))
                }.frame(width: 89, height: 42)
                    .foregroundStyle(.white)
                    .background(LinearGradient(colors: [Color(red: 0.96, green: 0.38, blue: 0.40), Color(red: 0.87, green: 0.20, blue: 0.27)], startPoint: .top, endPoint: .bottom), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .opacity(model.canStartRecording ? 1 : 0.5)
            }
            .buttonStyle(.plain).disabled(!model.canStartRecording).keyboardShortcut(.defaultAction)
            Button { dismissWindow() } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 42)
            }.buttonStyle(.plain).help("Close recorder").accessibilityLabel("Close recorder")
        }
        .disabled(isBusy)
        .padding(.horizontal, 12).frame(height: 64)
        .appGlassSurface(in: Capsule())
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 25)
    }

    private func deviceButton(_ item: InputPopover, icon: String, enabled: Bool) -> some View {
        Button { popover = item } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16)).frame(height: 19)
                Circle().fill(enabled ? Color.green : Color.clear).frame(width: 4, height: 4)
            }.foregroundStyle(enabled ? .primary : .secondary).frame(width: 32, height: 44)
        }
        .buttonStyle(RecorderControlStyle())
        .accessibilityLabel(item.title).accessibilityValue(enabled ? "On" : "Off").help(item.title)
    }

    @ViewBuilder
    private func devicePopover(_ item: InputPopover) -> some View {
        if item == .audio {
            Toggle("Record system sound", isOn: $model.includesSystemAudio).toggleStyle(.switch)
        } else {
            let isCamera = item == .camera
            let enabled = isCamera ? $model.includesCamera : $model.includesMicrophone
            let selection = isCamera ? $model.selectedCameraID : $model.selectedMicrophoneID
            let available = isCamera ? devices.cameras : devices.microphones
            Toggle(isCamera ? "Record camera" : "Record microphone", isOn: enabled)
                .toggleStyle(.switch).disabled(!isCamera && !supportsMicrophone)
            if !isCamera && !supportsMicrophone {
                Text("Microphone recording requires macOS 15.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Device", selection: selection) {
                Text("System default").tag(nil as String?)
                ForEach(available) { device in Text(device.name).tag(Optional(device.id)) }
            }.disabled(!enabled.wrappedValue)
            if enabled.wrappedValue {
                if isCamera {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.15))
                        if let image = devices.cameraImage {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "video").font(.title).foregroundStyle(.secondary)
                        }
                    }.frame(height: 142).clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    HStack(spacing: 3) {
                        ForEach(0..<24) { index in
                            Capsule().fill(Double(index) / 24 < devices.microphoneLevel ? Color.green : Color.primary.opacity(0.1))
                                .frame(height: 5)
                        }
                    }.accessibilityLabel("Microphone level").accessibilityValue("\(Int(devices.microphoneLevel * 100)) percent")
                }
                if let message = devices.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var supportsMicrophone: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }
}

private struct RecordingSourcePicker: View {
    @ObservedObject var model: AppModel
    var select: () -> Void
    @State private var kind: CaptureSourceDescriptor.Kind = .display

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.hasScreenRecordingPermission || !model.hasInputMonitoringPermission {
                if !model.hasScreenRecordingPermission {
                    permission("Screen Recording") { Task { await model.requestScreenRecordingPermission() } }
                }
                if !model.hasInputMonitoringPermission {
                    permission("Cursor & click tracking") { model.requestInputMonitoringPermission() }
                }
                Text("Enable access in System Settings to start recording.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Source type", selection: $kind) {
                    Text("Screen").tag(CaptureSourceDescriptor.Kind.display)
                    Text("Window").tag(CaptureSourceDescriptor.Kind.window)
                }.pickerStyle(.segmented)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(model.sources.filter { $0.descriptor.kind == kind }) { source in
                            Button { model.selectedSourceID = source.id; select() } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06))
                                        if let image = model.sourceThumbnails[source.id] {
                                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                        } else {
                                            Image(systemName: kind == .display ? "display" : "macwindow").foregroundStyle(.secondary)
                                        }
                                    }.frame(height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
                                    HStack(spacing: 4) {
                                        Text(source.descriptor.displayName).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if source.id == model.selectedSourceID { Image(systemName: "checkmark").foregroundStyle(.green) }
                                    }.font(.caption)
                                }.padding(7)
                                    .background(.primary.opacity(source.id == model.selectedSourceID ? 0.08 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityLabel(source.descriptor.displayName)
                                .accessibilityAddTraits(source.id == model.selectedSourceID ? [.isSelected] : [])
                                .task { await model.loadThumbnail(for: source, refresh: true) }
                        }
                    }
                    if !model.sources.contains(where: { $0.descriptor.kind == kind }) {
                        Text(model.isLoadingSources ? "Finding sources…" : "No windows available. Open a window, then refresh.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }.frame(height: 238)
            }
            Divider()
            HStack {
                Button { model.openProject() } label: { Label("Open recording…", systemImage: "folder") }
                Spacer()
                Button { Task { await model.refreshSources() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isLoadingSources).accessibilityLabel("Refresh sources")
            }.appGlassButton().font(.callout)
        }
        .onAppear { kind = model.selectedSource?.descriptor.kind ?? .display }
    }

    private func permission(_ title: String, action: @escaping () -> Void) -> some View {
        HStack { Text(title).font(.callout); Spacer(); Button("Allow", action: action).appGlassButton() }
    }
}

private struct RecordingStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 9) {
                Circle().fill(.red).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recording").font(.system(size: 12, weight: .semibold))
                    Text(duration).font(.system(size: 17, weight: .medium, design: .monospaced))
                }
            }
            Spacer(minLength: 0)
            Button { Task { await model.stopRecording() } } label: {
                HStack(spacing: 8) {
                    if model.isStartingOrStopping {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                    }
                    Text(model.isStartingOrStopping ? "Finishing…" : "Stop recording")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white).frame(width: 150, height: 46)
                .background(Color(red: 0.78, green: 0.10, blue: 0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(model.isStartingOrStopping)
            .keyboardShortcut(".", modifiers: [.command])
            .accessibilityLabel(model.isStartingOrStopping ? "Finishing recording" : "Stop recording")
            .help("Stop recording and open the editor (⌘.)")
        }
        .padding(.horizontal, 16).frame(height: 72)
        .appGlassSurface(in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(12)
    }

    private var duration: String {
        let seconds = max(0, Int(model.elapsedTime))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct RecorderControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0), in: Capsule())
            .contentShape(Capsule())
    }
}
