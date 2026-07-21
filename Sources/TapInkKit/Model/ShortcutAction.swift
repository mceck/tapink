import Foundation

/// Every user-facing rebindable action. `isGlobal` actions must fire even when no
/// TapInk window exists yet (only draw-mode activation needs this); everything
/// else only needs to apply once draw mode is already active.
public enum ShortcutAction: String, Codable, CaseIterable {
    case activateDrawMode
    case exitDrawMode
    case copyScreenshot
    case saveScreenshot
    case regionScreenshot
    case recordScreen
    case regionRecording
    case freezeBackground
    case clearCanvas
    case undo
    case redo
    case toolPen
    case toolHighlighter
    case toolSpotlight
    case toolText
    case toolMove
    case toolEraser
    case hideCanvas
    case toggleAutofade
    case shapeRectangle
    case shapeEllipse
    case shapeLine
    case shapeArrow
    case toggleSidebar
    case hideSidebar
    case nextColor

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
        case .recordScreen: return "Record Screen"
        case .regionRecording: return "Selected Area Recording"
        case .freezeBackground: return "Freeze Background"
        case .clearCanvas: return "Clear Canvas"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .toolPen: return "Pen Tool"
        case .toolHighlighter: return "Highlighter Tool"
        case .toolSpotlight: return "Spotlight Tool"
        case .toolText: return "Text Tool"
        case .toolMove: return "Move Tool"
        case .toolEraser: return "Eraser Tool"
        case .hideCanvas: return "Hide Canvas"
        case .toggleAutofade: return "Auto-Fade Drawings"
        case .shapeRectangle: return "Rectangle Shape"
        case .shapeEllipse: return "Ellipse Shape"
        case .shapeLine: return "Line Shape"
        case .shapeArrow: return "Arrow Shape"
        case .toggleSidebar: return "Toggle Sidebar"
        case .hideSidebar: return "Hide Sidebar"
        case .nextColor: return "Next Color"
        }
    }
}
