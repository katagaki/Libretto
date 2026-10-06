import SwiftUI

/// Undo and redo for a document.
///
/// Every change to the document, however it was made, passes through
/// `record(from:to:scope:)`, which registers the document as it was with the
/// document's undo manager. Snapshots rather than inverse operations: the
/// document is a value with copy-on-write storage, so a snapshot shares
/// everything the change left alone, and no edit can forget to be undoable.
@MainActor
@Observable
final class DocumentHistory {
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoActionName = ""
    private(set) var redoActionName = ""

    /// How long a pause ends a run of changes that would otherwise be one step.
    static let coalescingInterval: TimeInterval = 1
    /// A step keeps its own copy of every block the change touched, so on a
    /// long document an unbounded history is an unbounded amount of memory.
    static let levels = 100

    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var read: () -> WordDocument = { WordDocument() }
    @ObservationIgnored private var write: (WordDocument) -> Void = { _ in /* Replaced on attach. */ }
    /// Told after an undo or redo has put a document back, with the document
    /// it replaced, so the editor can put the selection back near it.
    @ObservationIgnored private var restored: (_ now: WordDocument, _ before: WordDocument) -> Void = { _, _ in
        // Replaced on attach.
    }

    /// The document an undo or redo has just written. SwiftUI reports the
    /// change a moment later, by which time the undo manager is no longer
    /// undoing; recognising it is how that report is kept off the stack.
    @ObservationIgnored private var restoring: WordDocument?
    @ObservationIgnored private var lastScope: EditScope?
    @ObservationIgnored private var lastChange = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func attach(
        to undoManager: UndoManager?,
        read: @escaping () -> WordDocument,
        write: @escaping (WordDocument) -> Void,
        restored: @escaping (_ now: WordDocument, _ before: WordDocument) -> Void
    ) {
        self.read = read
        self.write = write
        self.restored = restored
        guard undoManager !== self.undoManager else { return }
        self.undoManager = undoManager
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let undoManager else { return refresh() }
        undoManager.levelsOfUndo = Self.levels
        // Text fields in panels register their own steps with the same
        // manager; any change to the stacks is a reason to look again.
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    /// Notes a change the user made, unless it is one an undo or redo made.
    func record(from old: WordDocument, to new: WordDocument, scope: EditScope) {
        if let restoring {
            self.restoring = nil
            if restoring == new { return }
        }
        guard let undoManager, old != new else { return }

        let now = Date()
        defer {
            lastScope = scope
            lastChange = now
        }
        // A run of the same kind of change is one step: the step already on
        // the stack holds the document from before the run began.
        if scope.coalesces, scope == lastScope, undoManager.canUndo,
           now.timeIntervalSince(lastChange) < Self.coalescingInterval {
            return
        }
        register(restoring: old, named: scope.actionName, with: undoManager)
        refresh()
    }

    func undo() {
        guard let undoManager, undoManager.canUndo else { return }
        undoManager.undo()
        refresh()
    }

    func redo() {
        guard let undoManager, undoManager.canRedo else { return }
        undoManager.redo()
        refresh()
    }

    /// Registers putting `target` back. Run from inside an undo, the inverse
    /// it registers lands on the redo stack, and the other way round.
    private func register(restoring target: WordDocument, named name: String, with undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated {
                let current = history.read()
                history.register(restoring: current, named: name, with: undoManager)
                // An edit straight after an undo starts a step of its own.
                history.lastScope = nil
                history.restoring = target
                history.write(target)
                history.restored(target, current)
            }
        }
        undoManager.setActionName(name)
    }

    private func refresh() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
        undoActionName = undoManager?.undoActionName ?? ""
        redoActionName = undoManager?.redoActionName ?? ""
    }
}
