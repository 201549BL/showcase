import Foundation

struct EditorHistory<Snapshot: Equatable> {
    private struct Entry {
        let snapshot: Snapshot
        let actionName: String
    }

    private struct Transaction {
        let snapshot: Snapshot
        let actionName: String
    }

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var transaction: Transaction?
    private let capacity: Int

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    var hasActiveTransaction: Bool { transaction != nil }
    var undoActionName: String? { undoEntries.last?.actionName }
    var redoActionName: String? { redoEntries.last?.actionName }

    mutating func begin(snapshot: Snapshot, actionName: String) {
        guard transaction == nil else { return }
        transaction = Transaction(snapshot: snapshot, actionName: actionName)
    }

    @discardableResult
    mutating func commit(current: Snapshot) -> Bool {
        guard let transaction else { return false }
        self.transaction = nil
        guard transaction.snapshot != current else { return false }

        undoEntries.append(Entry(
            snapshot: transaction.snapshot,
            actionName: transaction.actionName
        ))
        if undoEntries.count > capacity {
            undoEntries.removeFirst(undoEntries.count - capacity)
        }
        redoEntries.removeAll()
        return true
    }

    mutating func cancel() {
        transaction = nil
    }

    mutating func undo(current: Snapshot) -> Snapshot? {
        guard let entry = undoEntries.popLast() else { return nil }
        transaction = nil
        redoEntries.append(Entry(snapshot: current, actionName: entry.actionName))
        return entry.snapshot
    }

    mutating func redo(current: Snapshot) -> Snapshot? {
        guard let entry = redoEntries.popLast() else { return nil }
        transaction = nil
        undoEntries.append(Entry(snapshot: current, actionName: entry.actionName))
        return entry.snapshot
    }
}
