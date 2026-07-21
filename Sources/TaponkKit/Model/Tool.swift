import AppKit

public enum ShapeKind: String, Codable, CaseIterable {
    case rectangle
    case ellipse
    case line
    case arrow

    public var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        }
    }

    public var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        }
    }

    /// The rebindable action that selects this shape — lets tooltips/menus look up the live
    /// binding instead of hardcoding a key that may have been reassigned in Settings.
    public var shortcutAction: ShortcutAction {
        switch self {
        case .rectangle: return .shapeRectangle
        case .ellipse: return .shapeEllipse
        case .line: return .shapeLine
        case .arrow: return .shapeArrow
        }
    }
}

public enum DrawingTool: String, Codable, CaseIterable {
    case pen
    case highlighter
    case shape
    case spotlight
    case text
    case move
    case eraser

    public var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .shape: return "Shape"
        case .spotlight: return "Spotlight"
        case .text: return "Text"
        case .move: return "Move"
        case .eraser: return "Eraser"
        }
    }

    /// For `.shape`, callers should prefer `ToolState.selectedShape.symbolName` — the shape
    /// tool's icon is whichever shape is currently selected, not a generic one. This case's
    /// value is just a sensible fallback for callers that don't special-case it.
    public var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "paintbrush.pointed.fill"
        case .shape: return "square.on.circle"
        case .spotlight: return "flashlight.on.fill"
        case .text: return "textformat"
        case .move: return "cursorarrow"
        case .eraser: return "eraser"
        }
    }

    /// The rebindable action that selects this tool — lets tooltips look up the live binding
    /// instead of hardcoding a key that may have been reassigned in Settings. `nil` for `.shape`:
    /// it no longer has a single generic shortcut of its own (click cycles to the last-used
    /// shape, long-press/right-click picks a specific one — see `ToolbarView.shapeButton`).
    public var shortcutAction: ShortcutAction? {
        switch self {
        case .pen: return .toolPen
        case .highlighter: return .toolHighlighter
        case .shape: return nil
        case .spotlight: return .toolSpotlight
        case .text: return .toolText
        case .move: return .toolMove
        case .eraser: return .toolEraser
        }
    }
}

public struct ToolState {
    public var selectedTool: DrawingTool = .pen
    public var selectedShape: ShapeKind = .rectangle
    public var color: NSColor = .systemYellow
    public var lineWidth: CGFloat = 4

    /// Fill color for shapes (rectangle/ellipse only — a line/arrow has no interior to fill).
    /// Only relevant while `.shape` is selected. Defaults to fully transparent, i.e. outline-only,
    /// matching every shape drawn before this existed.
    public var fillColor: NSColor = .clear

    /// The tool active right before a temporary hold-to-move gesture forced `selectedTool` to
    /// `.move` (see `DrawSessionCoordinator.beginTemporaryMoveTool`); `nil` when the hold isn't
    /// in effect. Exposed here (not just kept private in the coordinator) so `CanvasView`'s
    /// ⌘-scroll brush-size preview can target the tool actually being resized even though the
    /// default hold-to-move modifier is also ⌘, which has already flipped `selectedTool` to
    /// `.move` by the time the scroll event arrives.
    public var toolBeforeTemporaryMove: DrawingTool?

    /// The point size the text tool renders at for the current `lineWidth`.
    /// Shared between `CanvasView.beginTextEditing` and the toolbar's size
    /// swatch so the number the user sees is the size the text actually gets.
    public var textFontSize: CGFloat { 12 + lineWidth * 3 }

    /// The preset swatches shown in the toolbar's color popover, in the fixed order
    /// `DrawSessionCoordinator.selectNextColor()` cycles through — shared so the
    /// shortcut and the popover UI can never drift apart into two different lists.
    public static let colorPalette: [NSColor] = [
        .systemYellow, .systemRed, .systemOrange, .systemGreen,
        .systemBlue, .systemPurple, .white, .black,
    ]

    public init() {}
}
