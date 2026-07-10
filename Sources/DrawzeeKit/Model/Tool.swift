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
}

public enum DrawingTool: String, Codable, CaseIterable {
    case pen
    case highlighter
    case shape
    case spotlight
    case text
    case move
    case eraser
}

public struct ToolState {
    public var selectedTool: DrawingTool = .pen
    public var selectedShape: ShapeKind = .rectangle
    public var color: NSColor = .systemYellow
    public var lineWidth: CGFloat = 4

    /// The point size the text tool renders at for the current `lineWidth`.
    /// Shared between `CanvasView.beginTextEditing` and the toolbar's size
    /// swatch so the number the user sees is the size the text actually gets.
    public var textFontSize: CGFloat { 12 + lineWidth * 3 }

    public init() {}
}
