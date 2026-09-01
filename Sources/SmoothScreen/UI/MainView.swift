import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let editor = model.editor {
                ProjectEditorView(model: editor) {
                    model.closeEditor()
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()

                    if model.isRecording {
                        recordingView
                    } else {
                        sourcePicker
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .task {
            if model.editor == nil, model.sources.isEmpty {
                await model.refreshSources()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissionStatus()
        }
        .alert(item: $model.presentedError) { error in
            Alert(
                title: Text("SmoothScreen couldn’t continue"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text("SmoothScreen")
                    .font(.headline)
                Text(model.isRecording ? "Recording in progress" : "Choose what to record")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.isRecording {
                Button {
                    model.openProject()
                } label: {
                    Label("Open", systemImage: "folder")
                }

                Button {
                    Task { await model.refreshSources() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingSources || model.isStartingOrStopping)
            }
        }
        .padding(18)
    }

    private var sourcePicker: some View {
        VStack(spacing: 0) {
            if !model.hasInputMonitoringPermission || !model.hasScreenRecordingPermission {
                permissionBanner
                Divider()
            }

            if model.isLoadingSources && model.sources.isEmpty {
                Spacer()
                ProgressView("Finding displays and windows…")
                Spacer()
            } else if model.sources.isEmpty {
                ContentUnavailableView(
                    "No recording sources",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Grant Screen Recording permission, then refresh the list.")
                )
            } else {
                List(selection: $model.selectedSourceID) {
                    sourceSection(.display, title: "Displays", icon: "display")
                    sourceSection(.window, title: "Windows", icon: "macwindow")
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Record system audio", isOn: $model.includesSystemAudio)
                        .toggleStyle(.checkbox)
                    if #available(macOS 15, *) {
                        Toggle("Record microphone", isOn: $model.includesMicrophone)
                            .toggleStyle(.checkbox)
                    }
                }

                Spacer()

                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(model.selectedSource == nil || model.isStartingOrStopping)
            }
            .padding(18)

            if let recording = model.lastRecording {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved \(recording.eventCount.formatted()) input events")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        model.revealLastRecording()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Recording permissions needed")
                    .font(.subheadline.weight(.semibold))
                Text("Enable the missing permissions in Privacy & Security, then return to SmoothScreen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.hasScreenRecordingPermission {
                Button("Screen Recording") {
                    model.openScreenRecordingSettings()
                }
            }
            if !model.hasInputMonitoringPermission {
                Button("Input Monitoring") {
                    model.openInputMonitoringSettings()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.orange.opacity(0.08))
    }

    @ViewBuilder
    private func sourceSection(
        _ kind: CaptureSourceDescriptor.Kind,
        title: String,
        icon: String
    ) -> some View {
        let matchingSources = model.sources.filter { $0.descriptor.kind == kind }
        if !matchingSources.isEmpty {
            Section(title) {
                ForEach(matchingSources) { source in
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.descriptor.displayName)
                                .lineLimit(1)
                            Text(sourceResolution(source.descriptor))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(source.id)
                }
            }
        }
    }

    private var recordingView: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.red.opacity(0.12))
                    .frame(width: 120, height: 120)
                Circle()
                    .fill(.red)
                    .frame(width: 64, height: 64)
            }

            Text(formattedDuration(model.elapsedTime))
                .font(.system(size: 48, weight: .medium, design: .monospaced))
                .contentTransition(.numericText())

            if let source = model.selectedSource {
                Text("Recording \(source.descriptor.displayName)")
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop Recording", systemImage: "stop.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.isStartingOrStopping)

            Text("SmoothScreen is excluded from full-display captures.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceResolution(_ descriptor: CaptureSourceDescriptor) -> String {
        let width = Int((descriptor.frame.width * descriptor.scaleFactor).rounded())
        let height = Int((descriptor.frame.height * descriptor.scaleFactor).rounded())
        return "\(width) × \(height)"
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
