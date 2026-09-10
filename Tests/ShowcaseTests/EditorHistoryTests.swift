import Testing
@testable import Showcase

@Suite("Editor history")
struct EditorHistoryTests {
    @Test("A continuous edit becomes one undo step")
    func transactionCoalescing() {
        var history = EditorHistory<Int>()
        history.begin(snapshot: 1, actionName: "Move Zoom")

        let didCommit = history.commit(current: 4)
        #expect(didCommit)
        #expect(history.undoActionName == "Move Zoom")
        #expect(history.undo(current: 4) == 1)
        #expect(history.redo(current: 1) == 4)
    }

    @Test("No-op edits do not create history")
    func noOpEdit() {
        var history = EditorHistory<String>()
        history.begin(snapshot: "same", actionName: "Edit")

        let didCommit = history.commit(current: "same")
        #expect(!didCommit)
        #expect(history.undoActionName == nil)
    }

    @Test("A new edit clears redo history")
    func branchingHistory() {
        var history = EditorHistory<Int>()
        history.begin(snapshot: 1, actionName: "First")
        history.commit(current: 2)
        #expect(history.undo(current: 2) == 1)
        #expect(history.redoActionName == "First")

        history.begin(snapshot: 1, actionName: "Replacement")
        history.commit(current: 3)

        #expect(history.redoActionName == nil)
        #expect(history.undo(current: 3) == 1)
    }
}
