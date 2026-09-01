import SwiftUI

@main
struct SmoothScreenApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .commands {
            EditorUndoCommands()
            CommandGroup(after: .newItem) {
                Button("Refresh Sources") {
                    Task { await model.refreshSources() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isRecording)
            }
        }
    }
}
