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
    /// ⌘-scroll requests a new line width (see `scrollWheel`) — line width is owned by
    /// `DrawSessionCoordinator`, so this view can only ask for the change, not apply it itself.
    var onLineWidthChange: ((CGFloat) -> Void)?
    /// Erase progress (0...1) for an object currently auto-fading, nil for one
    /// that should render fully visible. Queried during `draw` so the animation
    /// stays inside the normal vector-replay pipeline instead of growing a
    /// second rendering path.
    var fadeProgressProvider: ((UUID) -> CGFloat?)?

    private var currentStrokePoints: [CGPoint] = []
    private var shapeStart: CGPoint?
    private var shapeCurrent: CGPoint?
    private var isDrawingInProgress = false

    /// Move-tool state: the set of currently selected object IDs, the subset
    /// being actively dragged (set at mouse-down), and the last drag location
    /// so each `mouseDragged` applies only the incremental delta.
    private var selectedObjectIDs: Set<UUID> = []
    private var movingObjectIDs: Set<UUID> = []
    private var lastMovePoint: CGPoint = .zero

    /// Marquee selection state (drag on empty space with the move tool).
    private var isMarqueeSelecting = false
    private var marqueeStart: CGPoint = .zero
    private var marqueeCurrent: CGPoint = .zero

    private var spotlightLayer: CAShapeLayer?
    private var spotlightRadius: CGFloat = 130
    private var spotlightPoint: CGPoint = .zero

    /// Momentary ring at the cursor while ⌘-scrolling the brush/shape width — a `CAShapeLayer`
    /// sublayer like `spotlightLayer` rather than part of the vector-replay `draw(_:)` pass,
    /// since it fades out on its own timer independent of any redraw trigger.
    private var brushPreviewLayer: CAShapeLayer?
    private var brushPreviewHideWorkItem: DispatchWorkItem?
    /// Tracks the global hide/unhide nesting so we don't over-unhide when
    /// hiding the system cursor during brush-size preview.
    private var isCursorHiddenForPreview = false
    private var activeTextView: CommittingTextView?
    /// The object being edited when `activeTextView` is re-editing an already-placed text
    /// (vs. authoring a brand new one), so `commitTextEditing` knows to update it in place
    /// instead of adding a new object, and `render` knows to skip drawing the stale copy
    /// underneath the live edit view.
    private var editingTextID: UUID?
    private var frozenBackgroundImage: NSImage?

    private var isSelectingRegion = false
    private var regionSelectionStart: CGPoint?
    private var regionSelectionCurrent: CGPoint?

    /// The region currently being recorded on this screen, if any — kept on screen for the
    /// whole recording (unlike `regionSelectionStart`/`Current` above, which only exist during
    /// the initial drag). `nil` outside of an active region recording.
    private var activeRecordingFrame: CGRect?

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
        // Even though cursor rects are unreliable on `.nonactivatingPanel`
        // overlay panels, AppKit does evaluate them during mouse clicks —
        // without a rect here, any click on the canvas resets the pointer to
        // arrow until the next `mouseMoved`/`mouseDragged`.
        addCursorRect(bounds, cursor: currentToolCursor)
    }

    // MARK: - Tool-appropriate cursors

    /// Minimum diameter for the dot cursor so a 1pt hairline stroke never
    /// shrinks the pointer to an invisible speck.
    private static let minDotDiameter: CGFloat = 8

    /// Caches dot cursors by diameter + color hash so we don't redraw on
    /// every mouse-move.
    private static var dotCursorCache: [String: NSCursor] = [:]

    /// The cursor appropriate for the current tool and panel state. Shared by
    /// `applyToolCursor` (called on every mouse move) and `resetCursorRects`
    /// (called by AppKit during mouse clicks / window ordering).
    private var currentToolCursor: NSCursor {
        if isSelectingRegion { return .crosshair }
        switch tool.selectedTool {
        case .pen:
            return dotCursor(diameter: max(Self.minDotDiameter, tool.lineWidth), color: tool.color, alpha: 1)
        case .highlighter:
            return dotCursor(diameter: max(Self.minDotDiameter, tool.lineWidth * 3), color: tool.color, alpha: 0.35)
        case .shape:  return .crosshair
        case .text:   return .iBeam
        case .spotlight, .move: return .arrow
        case .eraser: return Self.eraserCursor
        }
    }

    /// Sets the cursor that matches the currently active tool, or crosshair
    /// if the view is in region-selection mode. Called from `mouseMoved` and
    /// `mouseDragged` (which don't reset cursor rects automatically on
    /// non-key panels).
    private func applyToolCursor() {
        currentToolCursor.set()
    }

    /// Re-asserts the tool-appropriate cursor — call from outside when the
    /// tool/width changes while the pointer is already inside the view.
    func refreshCursor() {
        // Don't unhide while the brush-size preview ring is active — the
        /// scroll wheel handler owns cursor visibility during that interval
        /// and will unhide on its own 0.45 s timer (fixes a flicker where
        /// `onLineWidthChange` → Combine sink → `refreshCursor()` used to
        /// cancel `NSCursor.hide()` in the middle of a scroll sequence).
        if !isBrushPreviewActive {
            unhideCursorIfNeeded()
        }
        applyToolCursor()
    }

    private var isBrushPreviewActive: Bool {
        brushPreviewHideWorkItem != nil || brushPreviewLayer != nil
    }

    private func unhideCursorIfNeeded() {
        if isCursorHiddenForPreview {
            NSCursor.unhide()
            isCursorHiddenForPreview = false
        }
    }

    /// Returns a cached (or newly created) dot cursor for the given
    /// diameter, color and opacity — used by `currentToolCursor` to build
    /// the pen/highlighter pointer without immediately activating it.
    private func dotCursor(diameter: CGFloat, color: NSColor, alpha: CGFloat) -> NSCursor {
        let key = Self.dotCursorCacheKey(diameter: diameter, color: color, alpha: alpha)
        if let cached = Self.dotCursorCache[key] { return cached }
        let cursor = Self.makeDotCursor(diameter: diameter, color: color, alpha: alpha)
        Self.dotCursorCache[key] = cursor
        return cursor
    }

    private static func dotCursorCacheKey(diameter: CGFloat, color: NSColor, alpha: CGFloat) -> String {
        let d = Int(round(diameter))
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, _: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: nil)
        return "\(d)-\(Int(r * 255))-\(Int(g * 255))-\(Int(b * 255))-\(Int(alpha * 100))"
    }

    /// Draws a filled circle with a white outline, sized to the brush stroke
    /// width and tinted with the current tool color (using the given alpha
    /// so the highlighter cursor previews its semi-transparent look).
    private static func makeDotCursor(diameter: CGFloat, color: NSColor, alpha: CGFloat) -> NSCursor {
        let padding: CGFloat = 6
        let totalSize = diameter + padding * 2
        let image = NSImage(size: NSSize(width: totalSize, height: totalSize))
        image.lockFocus()

        let circleRect = CGRect(x: padding, y: padding, width: diameter, height: diameter)
        let fillColor = color.withAlphaComponent(alpha)

        // Dark outline shadow so the white ring stays legible on light backgrounds.
        let shadowPath = NSBezierPath(ovalIn: circleRect.insetBy(dx: -0.5, dy: -0.5))
        NSColor.black.withAlphaComponent(0.35).setStroke()
        shadowPath.lineWidth = 1
        shadowPath.stroke()

        // Fill with the selected color at the correct alpha.
        let fill = NSBezierPath(ovalIn: circleRect)
        fillColor.setFill()
        fill.fill()

        // Main white outline — visible on dark backgrounds.
        let path = NSBezierPath(ovalIn: circleRect)
        path.lineWidth = 1.5
        NSColor.white.setStroke()
        path.stroke()

        image.unlockFocus()

        return NSCursor(image: image, hotSpot: NSPoint(x: totalSize / 2, y: totalSize / 2))
    }

    /// An eraser icon drawn once and reused. Uses the SF Symbol
    /// "eraser.fill" (the solid variant — plain "eraser" renders as a hollow
    /// outline that reads poorly at cursor size) tinted white with a dark
    /// drop-shadow so it's visible on any background. Falls back to the pen
    /// cursor's filled-circle look (in white) if the symbol is unavailable.
    private static let eraserCursor: NSCursor = {
        makeEraserSymbolCursor() ?? makeDotCursor(diameter: 20, color: .white, alpha: 1)
    }()

    private static func makeEraserSymbolCursor() -> NSCursor? {
        guard let symbol = NSImage(systemSymbolName: "eraser.fill", accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        guard let configured = symbol.withSymbolConfiguration(config) else { return nil }

        // `NSImage.draw` doesn't actually recolor a template image just because
        // `NSColor.set()` was called beforehand — that only affects appearance-
        // aware controls (buttons, toolbar items). Drawn directly like this, the
        // glyph always rendered in its own default (black) color, which is why
        // this used to come out filled black instead of white. Manually tint by
        // drawing the glyph then compositing a solid fill on top with
        // `.sourceAtop`, which recolors only the already-opaque pixels.
        let blackGlyph = CanvasView.tinted(configured, color: .black)
        let whiteGlyph = CanvasView.tinted(configured, color: .white)

        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()

        let drawRect = CGRect(x: 2, y: 2, width: 20, height: 20)

        // Black outline — the white glyph drawn dead-center over several offset
        // copies of the black one leaves a thin black ring peeking out on every
        // side, giving a stroked-outline look instead of a flat drop shadow.
        let outlineOffset: CGFloat = 0.55
        let outlineOffsets: [CGVector] = [
            CGVector(dx: -outlineOffset, dy: 0), CGVector(dx: outlineOffset, dy: 0),
            CGVector(dx: 0, dy: -outlineOffset), CGVector(dx: 0, dy: outlineOffset),
            CGVector(dx: -outlineOffset, dy: -outlineOffset), CGVector(dx: outlineOffset, dy: -outlineOffset),
            CGVector(dx: -outlineOffset, dy: outlineOffset), CGVector(dx: outlineOffset, dy: outlineOffset),
        ]
        for offset in outlineOffsets {
            blackGlyph.draw(in: drawRect.offsetBy(dx: offset.dx, dy: offset.dy),
                            from: .zero, operation: .sourceOver,
                            fraction: 1, respectFlipped: true, hints: nil)
        }

        // White fill on top, dead-center.
        whiteGlyph.draw(in: drawRect, from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)

        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }

    /// Recolors a template image by drawing it, then compositing a solid fill
    /// over it with `.sourceAtop` (which only paints where the image was
    /// already opaque) — the correct way to tint a template `NSImage`, since
    /// `NSColor.set()` alone has no effect on a plain `draw(in:...)` call.
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
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
            applyToolCursor()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: - Region recording frame

    /// Shows (or clears, passing `nil`) a persistent border around the region being recorded.
    /// `rect` is in this view's own local coordinates, same as `onRegionSelected`'s rect.
    func setActiveRecordingFrame(_ rect: CGRect?) {
        activeRecordingFrame = rect
        needsDisplay = true
    }

    // MARK: - Mouse handling

    public override func mouseDown(with event: NSEvent) {
        // AppKit may reset the cursor during mouse-event delivery on
        // non-key panels — reassert the tool cursor immediately so the
        // user never sees a flash of arrow before the first drag.
        applyToolCursor()
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
            if let hit = topmostObject(at: point), case .text(let existing) = hit {
                beginEditingExistingText(existing)
            } else {
                beginTextEditing(at: point)
            }
        case .move:
            let hit = topmostObject(at: point)
            if event.clickCount >= 2, case .text(let existing)? = hit {
                beginEditingExistingText(existing)
                return
            }
            if let hit {
                if event.modifierFlags.contains(.shift) {
                    if selectedObjectIDs.contains(hit.id) {
                        selectedObjectIDs.remove(hit.id)
                    } else {
                        selectedObjectIDs.insert(hit.id)
                    }
                    movingObjectIDs = selectedObjectIDs
                } else {
                    if !selectedObjectIDs.contains(hit.id) {
                        selectedObjectIDs = [hit.id]
                    }
                    movingObjectIDs = selectedObjectIDs
                }
                lastMovePoint = point
                needsDisplay = true
            } else if !event.modifierFlags.contains(.shift), !selectedObjectIDs.isEmpty, let box = selectionBoundingBox, box.contains(point) {
                movingObjectIDs = selectedObjectIDs
                lastMovePoint = point
                needsDisplay = true
            } else {
                if !event.modifierFlags.contains(.shift) {
                    selectedObjectIDs = []
                    needsDisplay = true
                }
                isMarqueeSelecting = true
                marqueeStart = point
                marqueeCurrent = point
                movingObjectIDs = []
            }
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
        // Same reasoning as the crosshair above — `mouseMoved` doesn't fire
        // during a drag, so the tool cursor must be reasserted here too.
        applyToolCursor()
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
            if isMarqueeSelecting {
                marqueeCurrent = point
                needsDisplay = true
            } else {
                guard !movingObjectIDs.isEmpty else { return }
                let delta = CGPoint(x: point.x - lastMovePoint.x, y: point.y - lastMovePoint.y)
                document?.translate(ids: movingObjectIDs, by: delta)
                lastMovePoint = point
            }
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
        // AppKit can swap the cursor back to whatever was last *registered*
        // via `addCursorRect` right as a drag ends on these non-key panels —
        // not necessarily the arrow, but a stale entry from whichever tool was
        // active the last time `resetCursorRects` naturally fired (window
        // ordering/key changes), which can be any tool, not just the current
        // one. `mouseDown`/`mouseDragged` already reassert live, but only
        // invalidating here forces AppKit to re-register the *current* tool's
        // cursor too, so a later automatic reset can't resurrect a stale one.
        defer {
            applyToolCursor()
            window?.invalidateCursorRects(for: self)
        }
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
        if isMarqueeSelecting {
            defer {
                isMarqueeSelecting = false
                marqueeStart = .zero
                marqueeCurrent = .zero
                needsDisplay = true
            }
            let rect = CGRect(
                x: min(marqueeStart.x, marqueeCurrent.x), y: min(marqueeStart.y, marqueeCurrent.y),
                width: abs(marqueeCurrent.x - marqueeStart.x), height: abs(marqueeCurrent.y - marqueeStart.y)
            )
            guard rect.width > 4, rect.height > 4 else { return }
            let marqueeIDs = Set(
                (document?.objects(for: screenID) ?? []).filter { $0.boundingBox.intersects(rect) }.map(\.id)
            )
            if event.modifierFlags.contains(.shift) {
                selectedObjectIDs.formUnion(marqueeIDs)
            } else {
                selectedObjectIDs = marqueeIDs
            }
            return
        }
        movingObjectIDs = []
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
                endPoint: end, color: tool.color, width: tool.lineWidth, fillColor: tool.fillColor
            )
            document?.add(.shape(shape))
        default:
            break
        }
        needsDisplay = true
    }

    /// Spotlight: a plain scroll (no modifier needed) resizes the spot, since it's the one tool
    /// where scrolling has no other meaning. Every other tool: ⌘-scroll adjusts the brush/shape
    /// line width, which also drives the text tool's font size (`ToolState.textFontSize` is
    /// derived from `lineWidth`) — routed through `onLineWidthChange` since line width is owned
    /// by `DrawSessionCoordinator`, not this view.
    public override func scrollWheel(with event: NSEvent) {
        if tool.selectedTool == .spotlight {
            spotlightRadius = max(40, min(400, spotlightRadius - event.scrollingDeltaY))
            updateSpotlight(at: spotlightPoint)
            return
        }
        guard event.modifierFlags.contains(.command) else { return }
        let newWidth = max(1, min(40, tool.lineWidth - event.scrollingDeltaY * CanvasView.lineWidthScrollSensitivity))
        onLineWidthChange?(newWidth)
        // ⌘ is also the default hold-to-move modifier, which has already flipped
        // `selectedTool` to `.move` by the time this scroll event arrives — `toolBeforeTemporaryMove`
        // is what the user is actually resizing.
        let previewTool = tool.toolBeforeTemporaryMove ?? tool.selectedTool
        if previewTool == .pen || previewTool == .highlighter || previewTool == .shape {
            let diameter = previewTool == .highlighter ? newWidth * 3 : newWidth
            showBrushSizePreview(at: convert(event.locationInWindow, from: nil), diameter: diameter)
        }
    }

    /// Scaled down from spotlight radius's 1:1 sensitivity (its 40...400 range is ~9x wider
    /// than line width's 1...40), so a scroll gesture that feels natural for the spot doesn't
    /// blow straight through the whole brush-size range in a couple of ticks.
    private static let lineWidthScrollSensitivity: CGFloat = 0.12

    public override func mouseMoved(with event: NSEvent) {
        // Cursor rects (`resetCursorRects`) only reliably repaint the pointer on
        // this view's own key/main transitions, not on every move across a
        // non-key overlay panel — which is why the crosshair was sticking only
        // while the pointer stayed over the (key) toolbar. Re-asserting it here
        // rides the same `.activeAlways` tracking area that already makes the
        // spotlight tool work regardless of key status.
        applyToolCursor()
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
        spotlightRadius = 130
    }

    /// Called when the hotkey switches the tool to spotlight, so the mask appears at the
    /// current cursor position right away instead of waiting for the next `mouseMoved` —
    /// which otherwise wouldn't fire until the user actually moves the mouse. Only the
    /// screen the cursor is actually over ends up drawing anything, same as `mouseMoved`.
    func activateSpotlightAtCurrentMouseLocation() {
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = convert(windowPoint, from: nil)
        guard bounds.contains(viewPoint) else { return }
        updateSpotlight(at: viewPoint)
    }

    private func updateSpotlight(at point: CGPoint) {
        spotlightPoint = point
        if spotlightLayer == nil {
            let layer = CAShapeLayer()
            layer.fillRule = .evenOdd
            layer.fillColor = NSColor.black.withAlphaComponent(0.6).cgColor
            self.layer?.addSublayer(layer)
            spotlightLayer = layer
        }
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: CGRect(x: point.x - spotlightRadius, y: point.y - spotlightRadius, width: spotlightRadius * 2, height: spotlightRadius * 2))
        spotlightLayer?.frame = bounds
        spotlightLayer?.path = path
    }

    /// A white ring with a black shadow halo (rather than matching the brush color) stays
    /// legible at any brush color/background combination without needing a second layer.
    /// The system cursor is hidden while the ring is visible so only the ring previews
    /// the exact brush size without a distracting extra pointer on top.
    private func showBrushSizePreview(at point: CGPoint, diameter: CGFloat) {
        brushPreviewHideWorkItem?.cancel()
        if !isCursorHiddenForPreview {
            NSCursor.hide()
            isCursorHiddenForPreview = true
        }
        if brushPreviewLayer == nil {
            let layer = CAShapeLayer()
            layer.fillColor = NSColor.clear.cgColor
            layer.strokeColor = NSColor.white.cgColor
            layer.lineWidth = 1.5
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.7
            layer.shadowRadius = 1
            layer.shadowOffset = .zero
            self.layer?.addSublayer(layer)
            brushPreviewLayer = layer
        }
        brushPreviewLayer?.removeAllAnimations()
        brushPreviewLayer?.opacity = 1
        brushPreviewLayer?.frame = bounds
        brushPreviewLayer?.path = CGPath(
            ellipseIn: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter),
            transform: nil
        )

        let workItem = DispatchWorkItem { [weak self] in self?.hideBrushSizePreview() }
        brushPreviewHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func hideBrushSizePreview() {
        unhideCursorIfNeeded()
        guard let layer = brushPreviewLayer else { return }
        brushPreviewLayer = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.2
        layer.opacity = 0
        layer.add(fade, forKey: "fadeOut")
        CATransaction.commit()
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
        let textView = makeTextView(frame: NSRect(x: point.x, y: point.y - lineHeight / 2, width: 10, height: lineHeight), font: font, color: tool.color, lineHeight: lineHeight)
        presentTextView(textView)
    }

    /// Re-opens an already-placed text object for editing: click-to-edit with the text tool, or
    /// double-click-to-edit with the move tool (see `mouseDown`). The original object is hidden
    /// (via `editingTextID`, checked in `render`) rather than removed outright, so cancelling
    /// leaves it untouched.
    private func beginEditingExistingText(_ text: TextObject) {
        onTextEditingBegin?()
        editingTextID = text.id
        needsDisplay = true
        let font = NSFont.systemFont(ofSize: text.fontSize)
        let lineHeight = font.ascender - font.descender + font.leading
        let textView = makeTextView(frame: NSRect(x: 0, y: 0, width: 10, height: lineHeight), font: font, color: text.color, lineHeight: lineHeight)
        textView.string = text.string
        // `.string` assignment is programmatic, not user typing, so `didChangeText()` (which
        // would otherwise trigger the auto-grow `sizeToFit`) never fires — size it explicitly.
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()
        // The frame above is a placeholder at the origin; `measuredOrigin` tells us where *that*
        // frame would land the glyphs, so shifting by the difference from the object's actual
        // `origin` reproduces its exact on-screen position without hand-deriving the flipped-view
        // math a second time (this shift is a pure translation — see `measuredOrigin`'s doc comment).
        if let placeholderOrigin = measuredOrigin(of: textView) {
            textView.setFrameOrigin(CGPoint(
                x: textView.frame.origin.x + (text.origin.x - placeholderOrigin.x),
                y: textView.frame.origin.y + (text.origin.y - placeholderOrigin.y)
            ))
        }
        presentTextView(textView, selectAllText: true)
    }

    /// Shared setup for a freshly-configured `CommittingTextView`: no fill/box/border, just the
    /// real (now genuinely blinking, since the panel actually becomes key) insertion caret to
    /// mark where typing lands. Grows in both directions and never wraps — a single line stays a
    /// single line until Shift+Return explicitly starts a new one.
    private func makeTextView(frame: NSRect, font: NSFont, color: NSColor, lineHeight: CGFloat) -> CommittingTextView {
        let textView = CommittingTextView(frame: frame)
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.isRichText = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: lineHeight)
        return textView
    }

    private func presentTextView(_ textView: CommittingTextView, selectAllText: Bool = false) {
        textView.onCommit = { [weak self] in self?.commitTextEditing() }
        addSubview(textView)
        // This screen's overlay panel must actually become key for typed
        // characters to route here — only the toolbar panel is key by default.
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        if selectAllText {
            textView.selectAll(nil)
        }
        activeTextView = textView
        // `makeKeyAndOrderFront` can trigger AppKit's `resetCursorRects`,
        // which for a `.nonactivatingPanel` without cursor rects resets to
        // arrow — reassert the tool cursor immediately to prevent a flash.
        refreshCursor()
    }

    /// Where the glyphs currently in `textView` would land in this (non-flipped) canvas's
    /// coordinate space, measured from its actual rendered rect rather than re-derived from font
    /// metrics by hand — any hand-rolled offset drifts out of sync the moment the textView's
    /// padding/inset changes. `usedRect` is built from line-fragment rects, which start at the
    /// container's own x origin; the glyphs themselves start further right, inset by the
    /// fragment's `lineFragmentPadding` (5pt by default), which isn't reflected in `usedRect` at
    /// all. `nil` only if the view has no layout manager/container, which never happens for a
    /// `CommittingTextView` actually in the view hierarchy.
    ///
    /// Because this is a straightforward affine mapping of `textView`'s frame into this view's
    /// space, moving `textView` by some delta (frame size unchanged) moves the result by that
    /// same delta — `beginEditingExistingText` relies on exactly that to reposition a freshly
    /// laid-out text view onto an existing object's recorded `origin`.
    private func measuredOrigin(of textView: NSTextView) -> CGPoint? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: container)
        var usedRect = layoutManager.usedRect(for: container)
        usedRect.origin.x += textView.textContainerInset.width + container.lineFragmentPadding
        usedRect.origin.y += textView.textContainerInset.height
        return convert(usedRect, from: textView).origin
    }

    /// Live-syncs an in-progress text edit to the toolbar's current color/size while it's open,
    /// so both are visible updating in the editing textbox itself rather than only appearing
    /// once committed. No-op if no text is currently being edited/authored.
    func updateActiveTextAppearance(color: NSColor, fontSize: CGFloat) {
        guard let textView = activeTextView else { return }
        if textView.textColor?.isEqual(color) != true {
            textView.textColor = color
            textView.insertionPointColor = color
        }
        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            textView.sizeToFit()
        }
    }

    private func commitTextEditing() {
        guard let textView = activeTextView else { return }
        let editingID = editingTextID
        defer {
            textView.removeFromSuperview()
            activeTextView = nil
            editingTextID = nil
            onTextEditingEnd?()
            needsDisplay = true
        }
        let string = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = textView.textColor ?? tool.color
        let fontSize = textView.font?.pointSize ?? tool.textFontSize
        if let editingID {
            // Editing an existing object: an empty result deletes it (mirrors "nothing was
            // typed" discarding a brand-new one below), otherwise it's updated in place —
            // `updateText` deliberately isn't an undo step, same as move-tool dragging.
            if string.isEmpty {
                document?.remove(id: editingID)
            } else if let origin = measuredOrigin(of: textView) {
                document?.updateText(id: editingID) { object in
                    object.string = string
                    object.color = color
                    object.fontSize = fontSize
                    object.origin = origin
                }
            }
            return
        }
        guard !string.isEmpty, let origin = measuredOrigin(of: textView) else { return }
        let object = TextObject(screen: screenID, origin: origin, string: string, color: color, fontSize: fontSize)
        document?.add(.text(object))
    }

    func cancelTextEditing() {
        guard let textView = activeTextView else { return }
        textView.removeFromSuperview()
        activeTextView = nil
        editingTextID = nil
        onTextEditingEnd?()
        needsDisplay = true
    }

    // MARK: - Rendering

    public override func draw(_ dirtyRect: NSRect) {
        if let frozenBackgroundImage {
            frozenBackgroundImage.draw(in: bounds)
        } else {
            NSColor.clear.set()
            dirtyRect.fill()
        }

        document?.objects(for: screenID).forEach(render)
        drawSelectionHighlights()

        if isSelectingRegion {
            drawRegionSelectionOverlay()
        }

        if let activeRecordingFrame {
            drawActiveRecordingFrameOverlay(activeRecordingFrame)
        }

        if isMarqueeSelecting {
            drawMarqueeSelection()
        }

        if isDrawingInProgress {
            switch tool.selectedTool {
            case .pen, .highlighter:
                drawStroke(points: currentStrokePoints, color: tool.color, width: tool.lineWidth, highlighter: tool.selectedTool == .highlighter)
            case .shape:
                if let start = shapeStart, let end = shapeCurrent {
                    drawShape(kind: tool.selectedShape, start: start, end: end, color: tool.color, width: tool.lineWidth, fillColor: tool.fillColor)
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
        // Being actively re-edited (see `beginEditingExistingText`) — the live `activeTextView`
        // subview is standing in for it, so drawing the stale committed copy underneath would
        // show two overlapping copies (and a mismatched one, once color/size are live-edited).
        guard object.id != editingTextID else { return }
        let fade = fadeProgressProvider?(object.id) ?? 0
        guard fade < 1 else { return }
        switch object {
        case .stroke(let stroke):
            let points = fade > 0 ? StrokeGeometry.trailing(stroke.points, keepingFraction: 1 - fade) : stroke.points
            drawStroke(points: points, color: stroke.color, width: stroke.width, highlighter: stroke.isHighlighter)
        case .shape(let shape):
            let color = fade > 0 ? shape.color.withAlphaComponent(shape.color.alphaComponent * (1 - fade)) : shape.color
            let fillColor = fade > 0 ? shape.fillColor.withAlphaComponent(shape.fillColor.alphaComponent * (1 - fade)) : shape.fillColor
            drawShape(kind: shape.kind, start: shape.startPoint, end: shape.endPoint, color: color, width: shape.width, fillColor: fillColor)
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

    private func drawShape(kind: ShapeKind, start: CGPoint, end: CGPoint, color: NSColor, width: CGFloat, fillColor: NSColor) {
        let path = CanvasView.shapePath(kind: kind, start: start, end: end)
        // Only rectangle/ellipse have an interior to fill — a line/arrow's path isn't closed,
        // so filling it would produce a nonsensical shape rather than nothing.
        if (kind == .rectangle || kind == .ellipse), fillColor.alphaComponent > 0 {
            fillColor.setFill()
            path.fill()
        }
        color.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
    }

    /// Small enough to read as "softened corners" rather than a rounded-rect shape of its own;
    /// `NSBezierPath` clamps this down automatically on rectangles narrower/shorter than double
    /// the radius, so a thin drag never produces a self-intersecting outline.
    private static let rectangleCornerRadius: CGFloat = 2

    static func shapePath(kind: ShapeKind, start: CGPoint, end: CGPoint) -> NSBezierPath {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch kind {
        case .rectangle:
            return NSBezierPath(roundedRect: rect, xRadius: rectangleCornerRadius, yRadius: rectangleCornerRadius)
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

    /// Marks the region currently being recorded by dimming everything outside it — the same
    /// treatment `drawRegionSelectionOverlay` uses while dragging out the initial selection, so
    /// the recording indicator reads as a continuation of that same gesture rather than a new
    /// visual language. A flat fill with a crisp edge exactly on `rect`'s boundary can't leak into
    /// the recording no matter how precise the crop is — unlike a blurred glow, there's no soft
    /// falloff that could spread past the line, so nothing needs to be inset or clipped: the
    /// evenodd fill's "hole" simply never paints a single pixel inside `rect`.
    private func drawActiveRecordingFrameOverlay(_ rect: CGRect) {
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: rect))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()

        // Outset from `rect`, never centered on its edge: a stroke centered exactly on the crop
        // boundary would put half its width inside the recorded pixels. Offsetting it clear keeps
        // the frame purely cosmetic, the same way the earlier glow version stayed outside the crop.
        let border = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
        border.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.6).setStroke()
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

    // MARK: - Selection (move tool)

    /// The set of object IDs currently selected on this canvas.
    var currentSelectedObjectIDs: Set<UUID> { selectedObjectIDs }

    func clearSelection() {
        selectedObjectIDs = []
        movingObjectIDs = []
        needsDisplay = true
    }

    /// Union of all selected objects' bounding boxes on this screen, or nil
    /// if nothing is selected. Used to allow clicks anywhere inside the
    /// selection area to start a drag.
    private var selectionBoundingBox: CGRect? {
        guard !selectedObjectIDs.isEmpty, let objects = document?.objects(for: screenID) else { return nil }
        var union: CGRect?
        for object in objects where selectedObjectIDs.contains(object.id) {
            let box = object.boundingBox.insetBy(dx: -4, dy: -4)
            union = union?.union(box) ?? box
        }
        return union
    }

    /// Draws a light blue highlight around every selected object, so the user
    /// can see which objects will move together.
    private func drawSelectionHighlights() {
        guard !selectedObjectIDs.isEmpty else { return }
        guard let objects = document?.objects(for: screenID) else { return }
        for object in objects where selectedObjectIDs.contains(object.id) {
            let box = object.boundingBox.insetBy(dx: -4, dy: -4)
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: box).fill()
            let border = NSBezierPath(rect: box)
            border.lineWidth = 1.5
            NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
            border.stroke()
        }
    }

    /// Rubber-band selection rectangle drawn while dragging on empty space
    /// with the move tool.
    private func drawMarqueeSelection() {
        let rect = CGRect(
            x: min(marqueeStart.x, marqueeCurrent.x), y: min(marqueeStart.y, marqueeCurrent.y),
            width: abs(marqueeCurrent.x - marqueeStart.x), height: abs(marqueeCurrent.y - marqueeStart.y)
        )
        NSColor.systemBlue.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: rect).fill()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        NSColor.systemBlue.withAlphaComponent(0.5).setStroke()
        let dashes: [CGFloat] = [6, 4]
        border.setLineDash(dashes, count: 2, phase: 0)
        border.stroke()
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
            let path = CanvasView.shapePath(kind: shape.kind, start: shape.startPoint, end: shape.endPoint)
            // A filled rectangle/ellipse reads visually as a solid object, so its whole interior
            // should be grabbable, not just a band around the outline — matches the fill condition
            // `drawShape` itself uses. Unfilled shapes stay outline-only so their hollow interior
            // still lets a click reach through to whatever's drawn inside.
            if (shape.kind == .rectangle || shape.kind == .ellipse), shape.fillColor.alphaComponent > 0,
               path.cgPath.contains(point) {
                return true
            }
            return path.cgPath
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
