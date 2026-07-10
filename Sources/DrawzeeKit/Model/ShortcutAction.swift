import Foundation

/// Every user-facing rebindable action. `isGlobal` actions must fire even when no
/// Drawzee window exists yet (only draw-mode activation needs this); everything
/// else only needs to apply once draw mode is already active.
public enum ShortcutAction: String, Codable, CaseIterable {
    case activateDrawMode
    case exitDrawMode
    case copyScreenshot
    case saveScreenshot
    case regionScreenshot
    case freezeBackground
    case clearCanvas
    case undo
    case redo
    case toolPen
    case toolHighlighter
    case toolShape
    case toolSpotlight
    case toolText
    case hideCanvas

    public var isGlobal: Bool {
        self == .activateDrawMode
    }

    public var displayName: String {
        switch self {
        case .activateDrawMode: return "Activate Draw Mode"
        case .exitDrawMode: return "Exit Draw Mode"
        case .copyScreenshot: return "Copy Screenshot"
        case .saveScreenshot: return "Save Screenshot"
        case .regionScreenshot: return "Selected Area Screenshot"
        case .freezeBackground: return "Freeze Background"
        case .clearCanvas: return "Clear Canvas"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .toolPen: return "Pen Tool"
        case .toolHighlighter: return "Highlighter Tool"
        case .toolShape: return "Shape Tool"
        case .toolSpotlight: return "Spotlight Tool"
        case .toolText: return "Text Tool"
        case .hideCanvas: return "Hide Canvas"
        }
    }
}
