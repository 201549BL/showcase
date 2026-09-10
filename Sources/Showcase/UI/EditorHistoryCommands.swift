import SwiftUI

struct EditorHistoryActions {
    let undoActionName: String?
    let redoActionName: String?
    let undo: () -> Void
    let redo: () -> Void
}

private struct EditorHistoryActionsKey: FocusedValueKey {
    typealias Value = EditorHistoryActions
}

extension FocusedValues {
    var editorHistoryActions: EditorHistoryActions? {
        get { self[EditorHistoryActionsKey.self] }
        set { self[EditorHistoryActionsKey.self] = newValue }
    }
}

struct EditorUndoCommands: Commands {
    @FocusedValue(\.editorHistoryActions) private var history

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) {
                history?.undo()
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(history?.undoActionName == nil)

            Button(redoTitle) {
                history?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(history?.redoActionName == nil)
        }
    }

    private var undoTitle: String {
        history?.undoActionName.map { "Undo \($0)" } ?? "Undo"
    }

    private var redoTitle: String {
        history?.redoActionName.map { "Redo \($0)" } ?? "Redo"
    }
}
