import AppKit

public typealias ScreenID = CGDirectDisplayID

public struct StrokeObject: Identifiable {
    public let id = UUID()
    public var screen: ScreenID
    public var points: [CGPoint]
    public var color: NSColor
    public var width: CGFloat
    public var isHighlighter: Bool

    public init(screen: ScreenID, points: [CGPoint], color: NSColor, width: CGFloat, isHighlighter: Bool) {
        self.screen = screen
        self.points = points
        self.color = color
        self.width = width
        self.isHighlighter = isHighlighter
    }
}

public struct ShapeObject: Identifiable {
    public let id = UUID()
    public var screen: ScreenID
    public var kind: ShapeKind
    public var startPoint: CGPoint
    public var endPoint: CGPoint
    public var color: NSColor
    public var width: CGFloat
    /// Interior fill, `.clear` (the default) meaning outline-only. Only rendered for
    /// `.rectangle`/`.ellipse` — see `CanvasView.drawShape`.
    public var fillColor: NSColor

    public init(screen: ScreenID, kind: ShapeKind, startPoint: CGPoint, endPoint: CGPoint, color: NSColor, width: CGFloat, fillColor: NSColor = .clear) {
        self.screen = screen
        self.kind = kind
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.width = width
        self.fillColor = fillColor
    }
}

public struct TextObject: Identifiable {
    public let id = UUID()
    public var screen: ScreenID
    public var origin: CGPoint
    public var string: String
    public var color: NSColor
    public var fontSize: CGFloat

    public init(screen: ScreenID, origin: CGPoint, string: String, color: NSColor, fontSize: CGFloat) {
        self.screen = screen
        self.origin = origin
        self.string = string
        self.color = color
        self.fontSize = fontSize
    }
}

public enum DrawingObject: Identifiable {
    case stroke(StrokeObject)
    case shape(ShapeObject)
    case text(TextObject)

    public var id: UUID {
        switch self {
        case .stroke(let object): return object.id
        case .shape(let object): return object.id
        case .text(let object): return object.id
        }
    }

    public var screen: ScreenID {
        switch self {
        case .stroke(let object): return object.screen
        case .shape(let object): return object.screen
        case .text(let object): return object.screen
        }
    }

    /// A copy shifted by `delta`, preserving identity (`id` is a stored
    /// property, so struct copies keep it) — the move tool relies on that to
    /// keep dragging the same object across successive updates.
    public func translated(by delta: CGPoint) -> DrawingObject {
        switch self {
        case .stroke(var object):
            object.points = object.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            return .stroke(object)
        case .shape(var object):
            object.startPoint = CGPoint(x: object.startPoint.x + delta.x, y: object.startPoint.y + delta.y)
            object.endPoint = CGPoint(x: object.endPoint.x + delta.x, y: object.endPoint.y + delta.y)
            return .shape(object)
        case .text(var object):
            object.origin = CGPoint(x: object.origin.x + delta.x, y: object.origin.y + delta.y)
            return .text(object)
        }
    }

    /// The axis-aligned bounding box of this object's visible geometry, in its
    /// own canvas coordinate space. Used for marquee selection and selection
    /// highlight rendering.
    public var boundingBox: CGRect {
        switch self {
        case .stroke(let stroke):
            guard !stroke.points.isEmpty else { return .zero }
            let xs = stroke.points.map(\.x)
            let ys = stroke.points.map(\.y)
            let inset = stroke.width / 2
            let minX = xs.min()! - inset
            let maxX = xs.max()! + inset
            let minY = ys.min()! - inset
            let maxY = ys.max()! + inset
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .shape(let shape):
            let inset = shape.width / 2
            let minX = min(shape.startPoint.x, shape.endPoint.x) - inset
            let maxX = max(shape.startPoint.x, shape.endPoint.x) + inset
            let minY = min(shape.startPoint.y, shape.endPoint.y) - inset
            let maxY = max(shape.startPoint.y, shape.endPoint.y) + inset
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text(let text):
            let size = NSAttributedString(
                string: text.string,
                attributes: [.font: NSFont.systemFont(ofSize: text.fontSize)]
            ).size()
            return CGRect(origin: text.origin, size: size)
        }
    }
}
