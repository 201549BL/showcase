import SwiftUI

@main
struct ShowcaseApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView(model: model)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 520, height: 88)
        .commands {
            EditorUndoCommands()
            CommandGroup(after: .newItem) {
                Button("Refresh Sources") {
                    Task { await model.refreshSources() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isRecording || model.isStartingOrStopping || model.countdownRemaining != nil)
            }
        }
        MenuBarExtra(isInserted: Binding(get: { model.isRecording }, set: { _ in })) {
            Text("Recording in progress")
            Button(model.isStartingOrStopping ? "Finishing…" : "Stop recording") {
                Task { await model.stopRecording() }
            }
            .disabled(model.isStartingOrStopping)
        } label: {
            Label("REC", systemImage: "stop.circle.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}
