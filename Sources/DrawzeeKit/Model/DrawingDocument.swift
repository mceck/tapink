import Foundation

/// A single chronological log of drawing objects across every monitor, with one
/// global undo/redo stack. Undo/redo is intentionally not per-screen: all monitors
/// are visible simultaneously, so "undo my last action" has one obvious meaning
/// regardless of which physical screen that action landed on.
public final class DrawingDocument {
    public private(set) var objects: [DrawingObject] = []
    private var redoStack: [DrawingObject] = []

    /// Fired whenever the object list changes (add/undo/redo/clear), so views can redraw.
    public var onChange: (() -> Void)?

    public init() {}

    public func add(_ object: DrawingObject) {
        objects.append(object)
        redoStack.removeAll()
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
