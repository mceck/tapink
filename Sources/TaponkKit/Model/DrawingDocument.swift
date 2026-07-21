import Foundation

/// A single chronological log of drawing objects across every monitor, with one
/// global undo/redo stack. Undo/redo is intentionally not per-screen: all monitors
/// are visible simultaneously, so "undo my last action" has one obvious meaning
/// regardless of which physical screen that action landed on.
public final class DrawingDocument {
    public private(set) var objects: [DrawingObject] = []
    private var redoStack: [DrawingObject] = []
    private var clearedSnapshot: [DrawingObject]?

    /// Fired whenever the object list changes (add/undo/redo/clear/remove), so views can redraw.
    public var onChange: (() -> Void)?
    /// Fired only for genuinely new objects (not redo), so auto-fade can start
    /// its clock at commit time without re-scheduling revived objects.
    public var onAdd: ((DrawingObject) -> Void)?

    public init() {}

    public func add(_ object: DrawingObject) {
        objects.append(object)
        clearedSnapshot = nil
        redoStack.removeAll()
        onAdd?(object)
        onChange?()
    }

    public func undo() {
        if objects.isEmpty, let snapshot = clearedSnapshot {
            clearedSnapshot = nil
            objects = snapshot
            onChange?()
            return
        }
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

    /// Moves a set of objects in place. Same undo philosophy as the single-
    /// object variant: positional edits are not part of the undo history.
    public func translate(ids: Set<UUID>, by delta: CGPoint) {
        guard !ids.isEmpty else { return }
        var changed = false
        for id in ids {
            guard let index = objects.firstIndex(where: { $0.id == id }) else { continue }
            objects[index] = objects[index].translated(by: delta)
            changed = true
        }
        if changed { onChange?() }
    }

    /// Updates one text object's content/style/position in place — used when committing an edit
    /// to an already-placed text object (`CanvasView.beginEditingExistingText`). Same undo
    /// philosophy as `translate`: editing an existing object isn't a new "draw" action, so this
    /// doesn't touch the undo/redo stacks or change the object's position in paint order.
    /// No-ops if `id` doesn't refer to a text object (already removed, or a different kind).
    public func updateText(id: UUID, transform: (inout TextObject) -> Void) {
        guard let index = objects.firstIndex(where: { $0.id == id }),
              case .text(var object) = objects[index] else { return }
        transform(&object)
        objects[index] = .text(object)
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
        clearedSnapshot = objects
        objects.removeAll()
        redoStack.removeAll()
        onChange?()
    }

    public func objects(for screen: ScreenID) -> [DrawingObject] {
        objects.filter { $0.screen == screen }
    }
}
