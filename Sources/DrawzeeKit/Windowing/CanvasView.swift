import AppKit

/// Renders one screen's committed drawing objects plus whatever is currently being
/// drawn. Committed objects are always replayed from the vector list in `document`
/// (the single source of truth); this view never owns authoritative state itself.
public final class CanvasView: NSView {
    var screenID: ScreenID = 0
    weak var document: DrawingDocument?
    var toolProvider: (() -> ToolState)?
    var onTextEditingBegin: (() -> Void)?
    var onTextEditingEnd: (() -> Void)?
    var onRegionSelected: ((CGRect) -> Void)?
    /// Erase progress (0...1) for an object currently auto-fading, nil for one
    /// that should render fully visible. Queried during `draw` so the animation
    /// stays inside the normal vector-replay pipeline instead of growing a
    /// second rendering path.
    var fadeProgressProvider: ((UUID) -> CGFloat?)?

    private var currentStrokePoints: [CGPoint] = []
    private var shapeStart: CGPoint?
    private var shapeCurrent: CGPoint?
    private var isDrawingInProgress = false

    /// Move-tool drag state: the object grabbed at mouse-down and the last
    /// drag location, so each `mouseDragged` applies only the incremental
    /// delta (the document mutates in place; re-deriving from the original
    /// mouse-down point would double-apply movement).
    private var movingObjectID: UUID?
    private var lastMovePoint: CGPoint = .zero

    private var spotlightLayer: CAShapeLayer?
    private var activeTextView: CommittingTextView?
    private var frozenBackgroundImage: NSImage?

    private var isSelectingRegion = false
    private var regionSelectionStart: CGPoint?
    private var regionSelectionCurrent: CGPoint?

    private var tool: ToolState { toolProvider?() ?? ToolState() }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Without this, the first click on a canvas that isn't key only brings its
    /// panel to key status (AppKit's default focus-click behavior) and is
    /// swallowed rather than reaching `mouseDown`/`mouseDragged` — since
    /// `KeyablePanel` made these overlay panels genuinely able to become key,
    /// every tool switch would otherwise need a throwaway click before drawing
    /// actually started.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `.activeAlways` tracking areas deliver `mouseMoved:` regardless of whether
    /// this view's window is key or main — without it, spotlight would only work
    /// on whichever single screen happens to hold key status.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    public override func mouseExited(with event: NSEvent) {
        // Without this, the spotlight mask freezes at its last position on
        // whichever screen the cursor just left when moving to another monitor.
        clearSpotlight()
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if isSelectingRegion {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: - Freeze background

    func setFrozenBackground(_ image: NSImage?) {
        frozenBackgroundImage = image
        needsDisplay = true
    }

    // MARK: - Region screenshot selection

    /// Puts (or takes) this canvas into crosshair drag-to-select mode, without
    /// touching `toolState` — the previously selected drawing tool stays active
    /// once the selection is made or cancelled.
    func setRegionSelectionActive(_ active: Bool) {
        isSelectingRegion = active
        if !active {
            regionSelectionStart = nil
            regionSelectionCurrent = nil
        }
        // `addCursorRect` (in `resetCursorRects`) is the idiomatic way to scope the
        // crosshair to this view, but it only takes effect on the next mouse
        // enter/exit or explicit invalidation; setting it directly here as well
        // guarantees the cursor updates immediately even if the pointer is
        // already resting inside the view when selection mode toggles.
        if active {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: - Mouse handling

    public override func mouseDown(with event: NSEvent) {
        if isSelectingRegion {
            let point = convert(event.locationInWindow, from: nil)
            regionSelectionStart = point
            regionSelectionCurrent = point
            needsDisplay = true
            return
        }
        if activeTextView != nil {
            commitTextEditing()
        }
        let point = convert(event.locationInWindow, from: nil)
        switch tool.selectedTool {
        case .pen, .highlighter:
            isDrawingInProgress = true
            currentStrokePoints = [point]
        case .shape:
            isDrawingInProgress = true
            shapeStart = point
            shapeCurrent = point
        case .spotlight:
            break
        case .text:
            beginTextEditing(at: point)
        case .move:
            movingObjectID = topmostObject(at: point)?.id
            lastMovePoint = point
        case .eraser:
            if let hit = topmostObject(at: point) {
                document?.remove(id: hit.id)
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isSelectingRegion {
            // AppKit sends `mouseDragged`, not `mouseMoved`, for the rest of a
            // drag started with `mouseDown` — without reasserting here too, the
            // crosshair (kept alive via `mouseMoved` otherwise) would revert to
            // the arrow for the entire duration of the drag itself.
            NSCursor.crosshair.set()
            regionSelectionCurrent = point
            needsDisplay = true
            return
        }
        switch tool.selectedTool {
        case .pen, .highlighter:
            guard isDrawingInProgress else { return }
            currentStrokePoints.append(point)
            needsDisplay = true
        case .shape:
            guard isDrawingInProgress, let start = shapeStart else { return }
            shapeCurrent = CanvasView.constrainedShapePoint(
                from: start, to: point, kind: tool.selectedShape,
                shiftHeld: event.modifierFlags.contains(.shift)
            )
            needsDisplay = true
        case .move:
            guard let id = movingObjectID else { return }
            document?.translate(id: id, by: CGPoint(x: point.x - lastMovePoint.x, y: point.y - lastMovePoint.y))
            lastMovePoint = point
        case .eraser:
            // Keeping the eraser live during a drag turns "click each stroke"
            // into the natural "swipe across everything to erase" gesture.
            if let hit = topmostObject(at: point) {
                document?.remove(id: hit.id)
            }
        default:
            break
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if isSelectingRegion {
            defer {
                regionSelectionStart = nil
                regionSelectionCurrent = nil
                needsDisplay = true
            }
            guard let start = regionSelectionStart, let end = regionSelectionCurrent else { return }
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard rect.width > 4, rect.height > 4 else { return }
            onRegionSelected?(rect)
            return
        }
        movingObjectID = nil
        guard isDrawingInProgress else { return }
        isDrawingInProgress = false
        switch tool.selectedTool {
        case .pen, .highlighter:
            defer { currentStrokePoints = [] }
            guard currentStrokePoints.count > 1 else { return }
            let stroke = StrokeObject(
                screen: screenID, points: currentStrokePoints, color: tool.color,
                width: tool.lineWidth, isHighlighter: tool.selectedTool == .highlighter
            )
            document?.add(.stroke(stroke))
        case .shape:
            defer { shapeStart = nil; shapeCurrent = nil }
            guard let start = shapeStart, let end = shapeCurrent, start != end else { return }
            let shape = ShapeObject(
                screen: screenID, kind: tool.selectedShape, startPoint: start,
                endPoint: end, color: tool.color, width: tool.lineWidth
            )
            document?.add(.shape(shape))
        default:
            break
        }
        needsDisplay = true
    }

    public override func mouseMoved(with event: NSEvent) {
        // Cursor rects (`resetCursorRects`) only reliably repaint the pointer on
        // this view's own key/main transitions, not on every move across a
        // non-key overlay panel — which is why the crosshair was sticking only
        // while the pointer stayed over the (key) toolbar. Re-asserting it here
        // rides the same `.activeAlways` tracking area that already makes the
        // spotlight tool work regardless of key status.
        if isSelectingRegion {
            NSCursor.crosshair.set()
        }
        guard tool.selectedTool == .spotlight else {
            clearSpotlight()
            return
        }
        updateSpotlight(at: convert(event.locationInWindow, from: nil))
    }

    func clearSpotlight() {
        guard spotlightLayer != nil else { return }
        spotlightLayer?.removeFromSuperlayer()
        spotlightLayer = nil
    }

    private func updateSpotlight(at point: CGPoint) {
        if spotlightLayer == nil {
            let layer = CAShapeLayer()
            layer.fillRule = .evenOdd
            layer.fillColor = NSColor.black.withAlphaComponent(0.6).cgColor
            self.layer?.addSublayer(layer)
            spotlightLayer = layer
        }
        let radius: CGFloat = 130
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        spotlightLayer?.frame = bounds
        spotlightLayer?.path = path
    }

    // MARK: - Object hit-testing (move & eraser tools)

    /// Last-drawn wins, matching paint order: the object rendered on top is
    /// the one a click visually lands on.
    private func topmostObject(at point: CGPoint) -> DrawingObject? {
        document?.objects(for: screenID).reversed().first { $0.isHit(at: point) }
    }

    // MARK: - Text tool

    private func beginTextEditing(at point: CGPoint) {
        onTextEditingBegin?()
        let font = NSFont.systemFont(ofSize: tool.textFontSize)
        let lineHeight = font.ascender - font.descender + font.leading
        let textView = CommittingTextView(frame: NSRect(x: point.x, y: point.y - lineHeight / 2, width: 10, height: lineHeight))
        textView.font = font
        textView.textColor = tool.color
        textView.insertionPointColor = tool.color
        // Clean and minimal on purpose: no fill/box/border, just the real (now
        // genuinely blinking, since the panel actually becomes key) insertion
        // caret to mark where typing lands.
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.isRichText = false
        // Grows in both directions and never wraps — a single line stays a
        // single line until Shift+Return explicitly starts a new one.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: lineHeight)
        textView.onCommit = { [weak self] in self?.commitTextEditing() }
        addSubview(textView)
        // This screen's overlay panel must actually become key for typed
        // characters to route here — only the toolbar panel is key by default.
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        activeTextView = textView
    }

    private func commitTextEditing() {
        guard let textView = activeTextView else { return }
        let string = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !string.isEmpty, let layoutManager = textView.layoutManager, let container = textView.textContainer {
            // Measuring the glyphs' actual rendered rect (rather than re-deriving a
            // position from font metrics by hand) guarantees the committed text lands
            // exactly where the live editing view showed it — any hand-rolled offset
            // drifts out of sync the moment the textView's padding/inset changes.
            layoutManager.ensureLayout(for: container)
            var usedRect = layoutManager.usedRect(for: container)
            // `usedRect` is built from line-fragment rects, which start at the
            // container's own x origin — the glyphs themselves start further right,
            // inset by the fragment's `lineFragmentPadding` (5pt by default), which
            // isn't reflected in `usedRect` at all.
            usedRect.origin.x += textView.textContainerInset.width + container.lineFragmentPadding
            usedRect.origin.y += textView.textContainerInset.height
            // `usedRect` is in the (flipped) text view's own coordinate space;
            // `convert` maps it into this (non-flipped) canvas's space, handling the
            // flip for us.
            let rectInCanvas = convert(usedRect, from: textView)
            let object = TextObject(
                screen: screenID, origin: rectInCanvas.origin, string: string,
                color: tool.color, fontSize: textView.font?.pointSize ?? 24
            )
            document?.add(.text(object))
        }
        textView.removeFromSuperview()
        activeTextView = nil
        onTextEditingEnd?()
        needsDisplay = true
    }

    func cancelTextEditing() {
        guard let textView = activeTextView else { return }
        textView.removeFromSuperview()
        activeTextView = nil
        onTextEditingEnd?()
    }

    // MARK: - Rendering

    public override func draw(_ dirtyRect: NSRect) {
        if let frozenBackgroundImage {
            // `draw(in:)` always stretches the image's full pixel content into the destination
            // rect regardless of the image's declared `.size`, so this fills `bounds` correctly
            // even though the captured image's size is in pixels, not points.
            frozenBackgroundImage.draw(in: bounds)
        } else {
            NSColor.clear.set()
            dirtyRect.fill()
        }

        document?.objects(for: screenID).forEach(render)

        if isSelectingRegion {
            drawRegionSelectionOverlay()
        }

        if isDrawingInProgress {
            switch tool.selectedTool {
            case .pen, .highlighter:
                drawStroke(points: currentStrokePoints, color: tool.color, width: tool.lineWidth, highlighter: tool.selectedTool == .highlighter)
            case .shape:
                if let start = shapeStart, let end = shapeCurrent {
                    drawShape(kind: tool.selectedShape, start: start, end: end, color: tool.color, width: tool.lineWidth)
                }
            default:
                break
            }
        }
    }

    /// A mid-fade stroke is erased by retracing the original drawing motion:
    /// an invisible eraser starts at the stroke's first point and follows the
    /// path toward the last, so the still-visible part is the trailing
    /// fraction and the tip that vanishes last is where the pen lifted.
    /// Shapes and text have no draw direction to retrace, so they fade to
    /// transparent instead.
    private func render(_ object: DrawingObject) {
        let fade = fadeProgressProvider?(object.id) ?? 0
        guard fade < 1 else { return }
        switch object {
        case .stroke(let stroke):
            let points = fade > 0 ? StrokeGeometry.trailing(stroke.points, keepingFraction: 1 - fade) : stroke.points
            drawStroke(points: points, color: stroke.color, width: stroke.width, highlighter: stroke.isHighlighter)
        case .shape(let shape):
            let color = fade > 0 ? shape.color.withAlphaComponent(shape.color.alphaComponent * (1 - fade)) : shape.color
            drawShape(kind: shape.kind, start: shape.startPoint, end: shape.endPoint, color: color, width: shape.width)
        case .text(let text):
            drawText(text, alpha: 1 - fade)
        }
    }

    private func drawStroke(points: [CGPoint], color: NSColor, width: CGFloat, highlighter: Bool) {
        guard points.count > 1 else { return }
        let path = CanvasView.smoothedPath(through: points)
        path.lineWidth = highlighter ? width * 3 : width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.withAlphaComponent(highlighter ? 0.35 : 1.0).setStroke()
        path.stroke()
    }

    /// Raw mouse/trackpad samples arrive as a jagged polyline; connecting them with
    /// straight `line(to:)` segments (the old behavior) makes every stroke look
    /// faceted rather than hand-drawn, especially wherever the pointer moved fast
    /// enough that consecutive samples are far apart. This runs the standard
    /// "smoothed freehand line" construction: the curve passes through the
    /// *midpoint* between each pair of consecutive points, using the real point
    /// between them as the pull (control) point for a quadratic curve — so every
    /// sampled point still shapes the curve, but corners get rounded instead of
    /// kinked. The very first and last segments (point to first midpoint, last
    /// midpoint to point) are left straight, matching the algorithm's standard form.
    static func smoothedPath(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count > 2 else {
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            return path
        }

        path.move(to: points[0])
        var control = points[0]
        var upcoming = points[1]
        for index in 1..<points.count {
            let midpoint = CGPoint(x: (control.x + upcoming.x) / 2, y: (control.y + upcoming.y) / 2)
            appendQuadCurve(to: midpoint, control: control, on: path)
            control = points[index]
            upcoming = index + 1 < points.count ? points[index + 1] : points[index]
        }
        path.line(to: control)
        return path
    }

    /// `NSBezierPath` only exposes a cubic `curve(to:controlPoint1:controlPoint2:)`,
    /// so a quadratic curve (a single control point) is degree-elevated into the
    /// exact equivalent cubic: each cubic control point sits 2/3 of the way from
    /// its endpoint toward the quadratic control point.
    private static func appendQuadCurve(to end: CGPoint, control: CGPoint, on path: NSBezierPath) {
        let start = path.currentPoint
        let control1 = CGPoint(x: start.x + (control.x - start.x) * 2 / 3, y: start.y + (control.y - start.y) * 2 / 3)
        let control2 = CGPoint(x: end.x + (control.x - end.x) * 2 / 3, y: end.y + (control.y - end.y) * 2 / 3)
        path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
    }

    private func drawShape(kind: ShapeKind, start: CGPoint, end: CGPoint, color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = CanvasView.shapePath(kind: kind, start: start, end: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
    }

    static func shapePath(kind: ShapeKind, start: CGPoint, end: CGPoint) -> NSBezierPath {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch kind {
        case .rectangle:
            return NSBezierPath(rect: rect)
        case .ellipse:
            return NSBezierPath(ovalIn: rect)
        case .line:
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            return path
        case .arrow:
            return CanvasView.arrowPath(from: start, to: end)
        }
    }

    /// Holding Shift while dragging a rectangle/ellipse locks it to a square/circle
    /// (the common convention in design tools), sized to the larger of the two
    /// deltas so the shape keeps growing as the cursor moves along either axis.
    /// Line/arrow aren't directional in the same sense, so Shift is left alone
    /// for them here.
    static func constrainedShapePoint(from start: CGPoint, to point: CGPoint, kind: ShapeKind, shiftHeld: Bool) -> CGPoint {
        guard shiftHeld, kind == .rectangle || kind == .ellipse else { return point }
        let dx = point.x - start.x
        let dy = point.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(
            x: start.x + (dx < 0 ? -side : side),
            y: start.y + (dy < 0 ? -side : side)
        )
    }

    static func arrowPath(from start: CGPoint, to end: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 18
        let arrowAngle: CGFloat = .pi / 7
        let p1 = CGPoint(x: end.x - arrowLength * cos(angle - arrowAngle), y: end.y - arrowLength * sin(angle - arrowAngle))
        let p2 = CGPoint(x: end.x - arrowLength * cos(angle + arrowAngle), y: end.y - arrowLength * sin(angle + arrowAngle))
        // Each wing starts with its own `move(to:)` rather than continuing straight
        // from the shaft: without it, the shaft and the first wing form one
        // unbroken subpath with a sharp bend at `end`, and NSBezierPath's default
        // miter join spikes out past the intended triangle at that bend — visible
        // as a glitchy point stuck on one side of the arrowhead.
        path.move(to: end)
        path.line(to: p1)
        path.move(to: end)
        path.line(to: p2)
        return path
    }

    /// While armed but not yet dragging, dims the whole screen a little so it's
    /// obvious region-selection mode is active. Once a drag is in progress, the
    /// dim is punched out over the in-progress selection rect (even-odd fill)
    /// so the actual capture area reads at normal brightness with a border,
    /// matching the standard macOS screenshot-selection look.
    /// Same dim alpha in both branches on purpose — switching opacity the moment
    /// a drag starts reads as a jarring flash/second overlay rather than one
    /// continuous scrim with a hole punched in it.
    private func drawRegionSelectionOverlay() {
        let dimAlpha: CGFloat = 0.3
        guard let start = regionSelectionStart, let end = regionSelectionCurrent else {
            NSColor.black.withAlphaComponent(dimAlpha).setFill()
            bounds.fill()
            return
        }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: rect))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        dim.fill()

        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()
    }

    private func drawText(_ text: TextObject, alpha: CGFloat = 1) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: text.fontSize),
            .foregroundColor: text.color.withAlphaComponent(text.color.alphaComponent * alpha),
        ]
        // `text.origin` is the bottom-left of the glyphs' bounding rect (see
        // `commitTextEditing`); in this non-flipped view, `draw(at:)` anchors its
        // point at exactly that corner, so no extra offset is needed here.
        NSAttributedString(string: text.string, attributes: attributes).draw(at: text.origin)
    }
}

/// Hit-testing for the move and eraser tools. Lives here rather than in the
/// Model because "was this object clicked" is a question about its *rendered*
/// geometry, so it must reuse the exact same path construction the canvas
/// draws with (`smoothedPath`, `shapePath`) — a separate approximation would
/// drift the moment rendering changes.
extension DrawingObject {
    /// Grab/erase tolerance in points on each side of the visible geometry —
    /// generous enough that a hairline stroke doesn't demand pixel-perfect clicks.
    private static let hitTolerance: CGFloat = 8

    /// Whether `point` (in the object's own canvas coordinates) lands on its
    /// visible geometry: the smoothed stroke path, a shape's outline (not a
    /// rectangle/ellipse's hollow interior, which would otherwise block
    /// grabbing objects drawn inside it), or a text's bounding box.
    /// Stroke/outline proximity is computed by thickening the actual rendered
    /// path (`copy(strokingWithWidth:)`) and asking containment, so curves,
    /// arrowheads, and fat highlighter strokes all hit-test exactly as drawn
    /// rather than via bounding-box guesses.
    func isHit(at point: CGPoint) -> Bool {
        switch self {
        case .stroke(let stroke):
            guard stroke.points.count > 1 else { return false }
            let drawnWidth = stroke.isHighlighter ? stroke.width * 3 : stroke.width
            return CanvasView.smoothedPath(through: stroke.points).cgPath
                .copy(strokingWithWidth: drawnWidth + Self.hitTolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .contains(point)
        case .shape(let shape):
            return CanvasView.shapePath(kind: shape.kind, start: shape.startPoint, end: shape.endPoint).cgPath
                .copy(strokingWithWidth: shape.width + Self.hitTolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .contains(point)
        case .text(let text):
            let size = NSAttributedString(
                string: text.string,
                attributes: [.font: NSFont.systemFont(ofSize: text.fontSize)]
            ).size()
            // `text.origin` is the bottom-left of the rendered glyphs (see
            // `drawText`), so in this non-flipped space the box extends up-right.
            return CGRect(origin: text.origin, size: size)
                .insetBy(dx: -Self.hitTolerance, dy: -Self.hitTolerance)
                .contains(point)
        }
    }
}

/// A plain NSTextView that commits on Return instead of inserting a newline.
/// Escape-to-cancel is handled upstream by HotkeyManager, which intercepts the
/// key event before it ever reaches this view's responder chain.
final class CommittingTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)
        } else {
            onCommit?()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        // `isHorizontallyResizable`/`isVerticallyResizable` only auto-grow a text
        // view that's the document view of an `NSScrollView` — outside one (as
        // here), nothing actually resizes the frame on its own. Without this, the
        // view stays at its initial tiny size and clips everything typed beyond
        // it, so committing appears to "reveal" text that was invisible a moment
        // before. `ensureLayout` forces the glyph layout current before
        // `sizeToFit` measures it — otherwise it reads one keystroke stale.
        if let container = textContainer {
            layoutManager?.ensureLayout(for: container)
        }
        sizeToFit()
    }
}
