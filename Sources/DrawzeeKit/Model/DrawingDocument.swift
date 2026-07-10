import Foundation

/// A single chronological log of drawing objects across every monitor, with one
/// global undo/redo stack. Undo/redo is intentionally not per-screen: all monitors
/// are visible simultaneously, so "undo my last action" has one obvious meaning
/// regardless of which physical screen that action landed on.
public final class DrawingDocument {
    public private(set) var objects: [DrawingObject] = []
    private var redoStack: [DrawingObject] = []

    /// Fired whenever the object list changes (add/undo/redo/clear/remove), so views can redraw.
    public var onChange: (() -> Void)?
    /// Fired only for genuinely new objects (not redo), so auto-fade can start
    /// its clock at commit time without re-scheduling revived objects.
    public var onAdd: ((DrawingObject) -> Void)?

    public init() {}

    public func add(_ object: DrawingObject) {
        objects.append(object)
        redoStack.removeAll()
        onAdd?(object)
        onChange?()
    }

    public func undo() {
        guard let last = objects.popLast() else { return }
        redoStack.append(last)
        onChange?()
    }

    public func redo() {
        guard let object = redoStack.popLast() else { return }
        objects.append(object)
        onChange?()
    }

    /// Moves one object in place. Deliberately not an undo step (same as the
    /// eraser and auto-fade below): the undo stack models "objects in the
    /// order they were drawn", and splicing positional edits into it would
    /// turn "undo" from "take back my last drawing" into a mixed history.
    public func translate(id: UUID, by delta: CGPoint) {
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return }
        objects[index] = objects[index].translated(by: delta)
        onChange?()
    }

    /// Removes one specific object without touching the redo stack — used by
    /// the eraser tool and when an auto-fade erase completes. Neither is an
    /// undoable action: "undo" keeps meaning "take back my last drawing",
    /// not "resurrect what I explicitly (or automatically) erased".
    public func remove(id: UUID) {
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return }
        objects.remove(at: index)
        onChange?()
    }

    public func clear() {
        guard !objects.isEmpty else { return }
        objects.removeAll()
        redoStack.removeAll()
        onChange?()
    }

    public func objects(for screen: ScreenID) -> [DrawingObject] {
        objects.filter { $0.screen == screen }
    }
}
