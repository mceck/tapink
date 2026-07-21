import AppKit
import Combine
import SwiftUI

/// Which flavor of screen recording is currently in flight, or `nil` if none is. Only one
/// recording can be active at a time (see `DrawSessionCoordinator.toggleScreenRecording()` /
/// `beginRegionRecordingSelection()`).
public enum RecordingKind {
    case screen
    case region
}

/// Owns the drawing session end-to-end: one overlay per screen, the single
/// draggable toolbar, the shared document, and the currently selected tool.
/// This is the one place that decides which panel is key and how draw mode's
/// lifecycle plays out, so window-focus bugs have a single place to live.
public final class DrawSessionCoordinator: ObservableObject {
    /// Shared with `ToolbarView`'s content fade so the two animations line up.
    public static let sidebarAnimationDuration: TimeInterval = 0.2

    @Published public private(set) var isDrawModeActive = false
    @Published public private(set) var isCanvasHidden = false
    @Published public private(set) var isSidebarCollapsed = false
    @Published public private(set) var isSidebarHidden = false
    @Published public var toolState = ToolState()
    @Published public private(set) var isSelectingRegion = false
    @Published public private(set) var isBackgroundFrozen = false
    @Published public private(set) var isAutofadeEnabled = false
    @Published public private(set) var activeRecordingKind: RecordingKind?
    public private(set) var isEditingText = false

    /// What a completed region drag-select is *for* — the same crosshair selection flow
    /// (`isSelectingRegion`, `CanvasView.setRegionSelectionActive`) is shared by region
    /// screenshots and region recordings, so this records which one to actually perform once
    /// the drag finishes.
    private enum RegionSelectionPurpose {
        case screenshot
        case recording
    }
    private var pendingRegionPurpose: RegionSelectionPurpose = .screenshot

    public let document = DrawingDocument()
    private lazy var autofade = AutofadeController(document: document)

    private var overlayControllers: [OverlayWindowController] = []
    private let toolbarController = ToolbarPanelController()
    private let toastController = ToastPanelController()
    private let tooltipController = TooltipPanelController()
    private var screenObserver: NSObjectProtocol?
    private var previouslyActiveApp: NSRunningApplication?
    private var toolBeforeSpotlight: DrawingTool?
    /// Which screen currently shows the persistent region-recording frame overlay (see
    /// `CanvasView.setActiveRecordingFrame`), so `stopRecording()` knows where to clear it.
    private var activeRegionRecordingScreenID: ScreenID?
    /// Backstop that auto-stops a recording after `AppSettings.maxRecordingDurationMinutes`,
    /// since a recording no longer stops on its own when draw mode exits (see
    /// `disableDrawMode()`). Scheduled once a recording actually starts, cancelled in
    /// `stopRecording()`.
    private var recordingTimeoutTimer: Timer?

    /// Every TapInk-owned window that must never itself appear in a screenshot or recording —
    /// the toolbar, the toast HUD, and the hover-tooltip panel. `freezeBackground()`
    /// additionally excludes the overlay canvases themselves (see there).
    private var excludedCaptureWindowNumbers: [Int] {
        [toolbarController.windowNumber, toastController.windowNumber, tooltipController.windowNumber]
    }

    public init() {
        toolbarController.coordinator = self
        toolState.color = AppSettings.shared.brushColor
        toolState.fillColor = AppSettings.shared.shapeFillColor
        toolState.lineWidth = AppSettings.shared.brushLineWidth
        document.onChange = { [weak self] in
            guard let self else { return }
            // Undo/clear must also drop any scheduled fade for the removed
            // objects, or a stale timer would erase them again after a redo.
            self.autofade.pruneRemovedObjects(keeping: Set(self.document.objects.map(\.id)))
            self.redrawAllCanvases()
        }
        document.onAdd = { [weak self] object in self?.autofade.scheduleFade(for: object) }
        autofade.onNeedsRedraw = { [weak self] in self?.redrawAllCanvases() }
        rebuildOverlayWindows()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildOverlayWindows()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    private func rebuildOverlayWindows() {
        let currentIDs = Set(NSScreen.screens.compactMap(\.displayID))
        overlayControllers.removeAll { !currentIDs.contains($0.screenID) }

        let existingIDs = Set(overlayControllers.map(\.screenID))
        for screen in NSScreen.screens {
            guard let id = screen.displayID, !existingIDs.contains(id) else { continue }
            overlayControllers.append(OverlayWindowController(screen: screen, document: document, coordinator: self))
        }
        overlayControllers.forEach { $0.updateFrameIfNeeded() }

        if isDrawModeActive {
            overlayControllers.forEach { $0.showForDrawing() }
        }
    }

    private func redrawAllCanvases() {
        overlayControllers.forEach { $0.canvasView.needsDisplay = true }
    }

    // MARK: - Draw mode lifecycle

    public func toggleDrawMode() {
        isDrawModeActive ? disableDrawMode() : enableDrawMode()
    }

    public func enableDrawMode() {
        guard !isDrawModeActive else { return }
        // A `.nonactivatingPanel` can become key without showing a Dock icon or
        // stealing Cmd-Tab visibility, but it still needs TapInk to actually be
        // the active application to reliably receive real keyboard/mouse-moved
        // input — otherwise shortcuts, text entry, and the spotlight tool only
        // work sporadically depending on which app last held focus.
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication
        isDrawModeActive = true
        isCanvasHidden = false
        // A previous session may have left the sidebar collapsed; every fresh
        // session starts expanded regardless. That reset must be instantaneous —
        // no SwiftUI content fade, no panel-resize animation — since it happens
        // before the panel/toolbar is shown at all. `.animation(value:)` in
        // `ToolbarView` would otherwise animate this mutation too, so it's
        // explicitly wrapped in a disabled-animation transaction; only the
        // user-driven `toggleSidebarCollapsed()` below should ever animate.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSidebarCollapsed = false
        }
        toolbarController.setCollapsed(false, animated: false)
        isSidebarHidden = AppSettings.shared.startDrawModeWithSidebarHidden
        // Every fresh draw-mode session starts from a known, predictable tool
        // rather than whatever was left selected last time (e.g. spotlight).
        toolState.selectedTool = .pen
        toolBeforeSpotlight = nil
        toolState.toolBeforeTemporaryMove = nil
        overlayControllers.forEach { $0.canvasView.clearSelection() }
        // Same predictable-start philosophy as the tool reset above: auto-fade
        // is opt-in per session.
        isAutofadeEnabled = false
        autofade.setEnabled(false)
        unfreezeBackground()
        overlayControllers.forEach { $0.showForDrawing() }
        // The modern cooperative `NSApp.activate()` (macOS 14+) explicitly does
        // NOT guarantee activation ("the framework does not guarantee that the
        // app will be activated at all" — AppKit header). The older, forceful
        // API reliably steals keyboard focus, which is exactly what's needed
        // here for shortcuts/text-entry to actually reach TapInk.
        NSApp.activate(ignoringOtherApps: true)
        toolbarController.show(on: DrawSessionCoordinator.screenUnderCursor() ?? NSScreen.main, revealed: !isSidebarHidden)
        showToast("Draw Mode On", systemImage: "pencil.tip")
        NSLog("TapInk: enableDrawMode done, appActive=\(NSApp.isActive)")
    }

    public func disableDrawMode() {
        guard isDrawModeActive else { return }
        showToast("Draw Mode Off", systemImage: "pencil.slash")
        // A running recording deliberately survives Esc/exiting draw mode (it's no longer
        // tied to the session's lifecycle) — it only ends via `stopRecording()`, called either
        // by the user directly (status-item menu, or re-entering draw mode to toggle it off)
        // or by `recordingTimeoutTimer` once `AppSettings.maxRecordingDurationMinutes` elapses.
        isDrawModeActive = false
        // Guards against a missed modifier-up (e.g. the user cmd-tabbed away mid-hold, so
        // `HotkeyManager` never saw the release): without this, a stale non-nil value here would
        // make the *next* session's first `beginTemporaryMoveTool()` a no-op.
        toolState.toolBeforeTemporaryMove = nil
        // Anything still waiting to fade (or mid-erase) was already promised to
        // disappear; finish the erase now rather than resurrecting it whole the
        // next time draw mode opens. Must run before `setEnabled(false)`, which
        // instead *cancels* outstanding fades.
        autofade.finishImmediately()
        autofade.setEnabled(false)
        isAutofadeEnabled = false
        unfreezeBackground()
        overlayControllers.forEach { $0.hide() }
        toolbarController.hide()
        tooltipController.hide()
        previouslyActiveApp?.activate(options: [])
        previouslyActiveApp = nil
    }

    public func toggleHideCanvas() {
        isCanvasHidden.toggle()
        overlayControllers.forEach { $0.setCanvasHidden(isCanvasHidden) }
    }

    /// The panel resize and the SwiftUI content fade are two independent animation
    /// systems; running them at the same time let the shrinking/growing window
    /// clip the still-fading content mid-transition. Sequencing them — fade out
    /// then shrink, or grow then fade in — means content is never asked to render
    /// outside the panel's current bounds.
    public func toggleSidebarCollapsed() {
        if isSidebarCollapsed {
            toolbarController.setCollapsed(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarAnimationDuration) { [weak self] in
                guard let self else { return }
                withAnimation(.easeInOut(duration: Self.sidebarAnimationDuration)) {
                    self.isSidebarCollapsed = false
                }
            }
        } else {
            // `isSidebarCollapsed` is mutated here from inside a Button action, not
            // from an async callback, but explicitly wrapping it in `withAnimation`
            // (rather than relying solely on `ToolbarView`'s `.animation(value:)`)
            // is what reliably drives the fade-out — without it, this branch was
            // snapping the content away instantly instead of fading it.
            withAnimation(.easeInOut(duration: Self.sidebarAnimationDuration)) {
                isSidebarCollapsed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarAnimationDuration) { [weak self] in
                self?.toolbarController.setCollapsed(true)
            }
        }
    }

    /// Fully hides/reveals the toolbar panel, distinct from `toggleSidebarCollapsed()`:
    /// collapsing still leaves a small indicator on screen, this removes the panel
    /// entirely (no resize/fade animation to sequence, so it's a direct toggle).
    public func toggleSidebarHidden() {
        isSidebarHidden.toggle()
        toolbarController.setFullyHidden(isSidebarHidden)
    }

    // MARK: - Tool selection

    /// Spotlight is the one tool with an "off" state: re-selecting it while
    /// it's already active is a toggle back to whichever tool was selected
    /// right before it turned on, rather than a no-op.
    public func selectTool(_ tool: DrawingTool) {
        if tool == .spotlight, toolState.selectedTool == .spotlight {
            toolState.selectedTool = toolBeforeSpotlight ?? .pen
            toolBeforeSpotlight = nil
            announceCurrentTool()
            return
        }
        if tool == .spotlight {
            toolBeforeSpotlight = toolState.selectedTool
        }
        if toolState.selectedTool == .move, tool != .move {
            overlayControllers.forEach { $0.canvasView.clearSelection() }
        }
        guard toolState.selectedTool != tool else { return }
        toolState.selectedTool = tool
        announceCurrentTool()
    }

    /// Called by `HotkeyManager` when `AppSettings.temporaryMoveToolModifier` goes down/up while
    /// draw mode is active — a quick way to nudge things around without leaving whatever tool is
    /// currently selected. Bypasses `selectTool()` (and its toast) entirely: this is meant to be
    /// tapped rapidly and repeatedly, and announcing every hold would be more noise than signal
    /// (same reasoning as spotlight's silence in `announceCurrentTool()`).
    public func beginTemporaryMoveTool() {
        guard toolState.toolBeforeTemporaryMove == nil else { return }
        toolState.toolBeforeTemporaryMove = toolState.selectedTool
        toolState.selectedTool = .move
    }

    public func endTemporaryMoveTool() {
        guard let previousTool = toolState.toolBeforeTemporaryMove else { return }
        toolState.toolBeforeTemporaryMove = nil
        if toolState.selectedTool == .move, previousTool != .move {
            overlayControllers.forEach { $0.canvasView.clearSelection() }
        }
        toolState.selectedTool = previousTool
    }

    public func setColor(_ color: NSColor) {
        toolState.color = color
        AppSettings.shared.brushColor = color
    }

    /// Shape fill is independent of the stroke color set above — see `ToolState.fillColor`.
    public func setFillColor(_ color: NSColor) {
        toolState.fillColor = color
        AppSettings.shared.shapeFillColor = color
    }

    /// Advances to the next swatch in `ToolState.colorPalette`, wrapping around at the end.
    /// If the current color isn't one of the presets (e.g. a custom color from the picker),
    /// this wraps to the first preset rather than matching by proximity.
    public func selectNextColor() {
        let palette = ToolState.colorPalette
        guard !palette.isEmpty else { return }
        let currentIndex = palette.firstIndex(where: { $0.isEqual(toolState.color) }) ?? -1
        setColor(palette[(currentIndex + 1) % palette.count])
    }

    public func setLineWidth(_ width: CGFloat) {
        toolState.lineWidth = width
        AppSettings.shared.brushLineWidth = width
    }

    public func setShape(_ shape: ShapeKind) {
        let changed = toolState.selectedShape != shape || toolState.selectedTool != .shape
        // Batch both mutations into a single struct assignment so `@Published`
        // only fires once — otherwise Combine subscribers see an intermediate
        // state where `selectedTool` is still the old tool and briefly set the
        // previous tool's cursor (the main source of cursor flicker on tool change).
        var newState = toolState
        newState.selectedShape = shape
        newState.selectedTool = .shape
        toolState = newState
        if changed { announceCurrentTool() }
    }

    // MARK: - Toast feedback

    /// Brief HUD feedback for draw-mode toggling and tool changes, shown on whichever screen
    /// currently hosts the toolbar. Excluded from screenshots/recordings via
    /// `excludedCaptureWindowNumbers`.
    private func showToast(_ message: String, systemImage: String) {
        toastController.show(message: message, systemImage: systemImage, on: toolbarController.currentScreen)
    }

    /// `windowLocalFrame` is a sidebar button's frame in the toolbar panel's own (window-base)
    /// coordinate system — `ToolbarView`'s tooltip modifier reports it this way via
    /// `NSView.convert(_:to: nil)`, sidestepping any AppKit/SwiftUI coordinate-flip math here.
    public func showTooltip(_ text: String, forButtonAt windowLocalFrame: CGRect) {
        let buttonFrameOnScreen = toolbarController.screenFrame(forWindowLocalRect: windowLocalFrame)
        tooltipController.show(
            text: text,
            besideButtonAt: buttonFrameOnScreen,
            toolbarFrameOnScreen: toolbarController.frameOnScreen,
            on: toolbarController.currentScreen
        )
    }

    public func hideTooltip() {
        tooltipController.hide()
    }

    /// `.shape` announces the specific selected shape (e.g. "Rectangle"), not a generic "Shape"
    /// — that's the actually-useful information when the shape tool is (re)selected. Spotlight is
    /// deliberately silent: it's toggled far more often/rapidly than other tools (mouse-driven,
    /// on-off-on in quick succession while pointing things out), so a toast for it would be more
    /// noise than signal.
    private func announceCurrentTool() {
        guard toolState.selectedTool != .spotlight else { return }
        if toolState.selectedTool == .shape {
            showToast(toolState.selectedShape.displayName, systemImage: toolState.selectedShape.symbolName)
        } else {
            showToast(toolState.selectedTool.displayName, systemImage: toolState.selectedTool.symbolName)
        }
    }

    // MARK: - Auto-fade

    /// Applies to objects committed from now on (a stroke already in progress
    /// counts: its fade clock starts at mouse-up, which lands after this).
    /// Existing drawings remain on screen — only new strokes/shapes/text will
    /// auto-fade after the configured delay.
    /// Toggling off leaves everything currently on screen permanent.
    public func toggleAutofade() {
        isAutofadeEnabled.toggle()
        autofade.setEnabled(isAutofadeEnabled)
        showToast(isAutofadeEnabled ? "Auto-Fade On" : "Auto-Fade Off", systemImage: "timer")
    }

    /// Render-time query for canvases: erase progress in 0...1 for an object
    /// mid-fade, nil for one that should draw fully visible.
    func fadeProgress(for objectID: UUID) -> CGFloat? {
        autofade.progress(for: objectID)
    }

    // MARK: - Text editing handoff

    public func beginTextEditing() { isEditingText = true }

    public func endTextEditing() {
        isEditingText = false
        toolbarController.reclaimKey()
    }

    public func cancelTextEditing() {
        isEditingText = false
        overlayControllers.forEach { $0.cancelTextEditing() }
        toolbarController.reclaimKey()
    }

    // MARK: - Freeze background

    /// The only place a freeze/unfreeze toast is shown — `freezeBackground()`/`unfreezeBackground()`
    /// are also called internally as a state reset (e.g. `enableDrawMode()`/`disableDrawMode()`
    /// unfreezing on the way in/out), which shouldn't announce anything.
    public func toggleFreezeBackground() {
        if isBackgroundFrozen {
            unfreezeBackground()
            showToast("Background Unfrozen", systemImage: "snowflake")
        } else {
            freezeBackground()
            // `freezeBackground()` no-ops (via its own guard) when draw mode isn't active;
            // only announce it if it actually took effect.
            if isBackgroundFrozen {
                showToast("Background Frozen", systemImage: "snowflake")
            }
        }
    }

    public func freezeBackground() {
        guard isDrawModeActive, !isBackgroundFrozen else { return }
        isBackgroundFrozen = true
        // Exclude every one of TapInk's own windows (toolbar + every overlay canvas) so the
        // frozen backdrop is a clean shot of what's underneath — existing drawn objects stay
        // vector-only in `document` and keep replaying on top each frame, so undo/redo/clear
        // still work normally against a frozen background.
        let excludedWindowNumbers = excludedCaptureWindowNumbers + overlayControllers.map(\.windowNumber)
        let controllers = overlayControllers
        Task { @MainActor in
            for controller in controllers {
                let image = await ScreenshotService.shared.captureImage(
                    displayID: controller.screenID,
                    excludingWindowNumbers: excludedWindowNumbers
                )
                controller.setFrozenBackground(image)
            }
        }
    }

    public func unfreezeBackground() {
        guard isBackgroundFrozen else { return }
        isBackgroundFrozen = false
        overlayControllers.forEach { $0.setFrozenBackground(nil) }
    }

    // MARK: - Screenshot

    static func screenUnderCursor() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }

    public func captureScreenshot(saveToDisk: Bool) {
        guard let screen = DrawSessionCoordinator.screenUnderCursor() ?? NSScreen.main,
              let displayID = screen.displayID else { return }
        let excludedWindowNumbers = excludedCaptureWindowNumbers
        // `@MainActor` here matters, not just style: without it, resuming after the `await`
        // below isn't guaranteed to land back on the main thread, and `showToast` touches
        // AppKit windows — this was the exact cause of a crash before it was added.
        Task { @MainActor in
            let captured = await ScreenshotService.shared.capture(
                displayID: displayID,
                excludingWindowNumbers: excludedWindowNumbers,
                saveToDisk: saveToDisk
            )
            if captured {
                showToast(saveToDisk ? "Screenshot Saved" : "Screenshot Copied", systemImage: "camera.fill")
            }
        }
    }

    // MARK: - Selected-area screenshot

    /// Puts every screen's canvas into crosshair drag-to-select mode. The user
    /// can start the drag on whichever monitor they want; the previously
    /// selected drawing tool is left untouched and resumes once the selection
    /// is made (or cancelled).
    public func beginRegionScreenshotSelection() {
        guard isDrawModeActive, !isSelectingRegion else { return }
        pendingRegionPurpose = .screenshot
        isSelectingRegion = true
        overlayControllers.forEach { $0.setRegionSelectionActive(true) }
    }

    public func cancelRegionSelection() {
        guard isSelectingRegion else { return }
        isSelectingRegion = false
        pendingRegionPurpose = .screenshot
        overlayControllers.forEach { $0.setRegionSelectionActive(false) }
    }

    /// Called by whichever screen's `CanvasView` the drag actually happened on.
    /// `rectInPoints` is in that screen's own view-local coordinates (origin at
    /// its bottom-left, matching `NSScreen.frame`'s size), which is exactly what
    /// `ScreenshotService`/`ScreenRecordingService` need to convert into their own
    /// coordinate spaces. Which action actually runs depends on `pendingRegionPurpose` —
    /// the same crosshair drag-select flow is shared by region screenshots and recordings.
    func completeRegionSelection(screenID: ScreenID, rectInPoints: CGRect) {
        isSelectingRegion = false
        overlayControllers.forEach { $0.setRegionSelectionActive(false) }
        switch pendingRegionPurpose {
        case .screenshot:
            captureRegionScreenshot(screenID: screenID, rectInPoints: rectInPoints)
        case .recording:
            startRegionRecording(screenID: screenID, rectInPoints: rectInPoints)
        }
    }

    private func captureRegionScreenshot(screenID: ScreenID, rectInPoints: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == screenID }) else { return }
        let excludedWindowNumbers = excludedCaptureWindowNumbers
        let saveToDisk = AppSettings.shared.regionScreenshotDestination == .file
        Task { @MainActor in
            let captured = await ScreenshotService.shared.captureRegion(
                displayID: screenID,
                regionInPoints: rectInPoints,
                scale: screen.backingScaleFactor,
                excludingWindowNumbers: excludedWindowNumbers,
                saveToDisk: saveToDisk
            )
            if captured {
                showToast(saveToDisk ? "Screenshot Saved" : "Screenshot Copied", systemImage: "camera.fill")
            }
        }
    }

    // MARK: - Screen recording

    /// Starts or stops a full-screen recording of whichever screen is under the cursor. Only one
    /// recording (full-screen or region) can be active at a time.
    public func toggleScreenRecording() {
        if activeRecordingKind != nil {
            stopRecording()
            return
        }
        guard let screen = DrawSessionCoordinator.screenUnderCursor() ?? NSScreen.main,
              let displayID = screen.displayID else { return }
        let excludedWindowNumbers = excludedCaptureWindowNumbers
        activeRecordingKind = .screen
        Task { @MainActor in
            let started = await ScreenRecordingService.shared.startFullScreen(
                displayID: displayID,
                excludingWindowNumbers: excludedWindowNumbers
            )
            if started {
                scheduleRecordingTimeout()
            } else {
                activeRecordingKind = nil
            }
        }
    }

    /// Puts every screen's canvas into the same crosshair drag-to-select mode used for region
    /// screenshots; once a rect is picked, `completeRegionSelection` routes it here instead.
    public func beginRegionRecordingSelection() {
        guard isDrawModeActive, !isSelectingRegion, activeRecordingKind == nil else { return }
        pendingRegionPurpose = .recording
        isSelectingRegion = true
        overlayControllers.forEach { $0.setRegionSelectionActive(true) }
    }

    /// Starts a region-recording selection, or stops the current one if a region recording is
    /// already in progress — the region counterpart to `toggleScreenRecording()`.
    public func toggleRegionRecording() {
        if activeRecordingKind == .region {
            stopRecording()
        } else {
            beginRegionRecordingSelection()
        }
    }

    private func startRegionRecording(screenID: ScreenID, rectInPoints: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == screenID }) else { return }
        let excludedWindowNumbers = excludedCaptureWindowNumbers
        activeRecordingKind = .region
        activeRegionRecordingScreenID = screenID
        // Kept on screen for the whole recording (unlike the transient drag-select overlay),
        // so the user can see exactly what's being captured — see `CanvasView
        // .setActiveRecordingFrame`'s doc comment for why it's drawn outside the crop rect.
        overlayControllers.first(where: { $0.screenID == screenID })?.setActiveRecordingFrame(rectInPoints)
        Task { @MainActor in
            let started = await ScreenRecordingService.shared.startRegion(
                displayID: screenID,
                regionInPoints: rectInPoints,
                screenHeightInPoints: screen.frame.height,
                scale: screen.backingScaleFactor,
                excludingWindowNumbers: excludedWindowNumbers
            )
            if started {
                scheduleRecordingTimeout()
            } else {
                activeRecordingKind = nil
                activeRegionRecordingScreenID = nil
                overlayControllers.first(where: { $0.screenID == screenID })?.setActiveRecordingFrame(nil)
            }
        }
    }

    /// Schedules (replacing any existing schedule) the backstop that force-stops the current
    /// recording after `AppSettings.maxRecordingDurationMinutes`. `.common` run-loop mode so it
    /// still fires while the user's interacting with menus/dragging elsewhere, matching
    /// `AutofadeController`'s timers.
    private func scheduleRecordingTimeout() {
        recordingTimeoutTimer?.invalidate()
        let timer = Timer(timeInterval: AppSettings.shared.maxRecordingDurationMinutes * 60, repeats: false) { [weak self] _ in
            self?.stopRecording()
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimeoutTimer = timer
    }

    /// Stops whichever recording (screen or region) is currently active. No-op if none is.
    public func stopRecording() {
        guard activeRecordingKind != nil else { return }
        recordingTimeoutTimer?.invalidate()
        recordingTimeoutTimer = nil
        activeRecordingKind = nil
        if let screenID = activeRegionRecordingScreenID {
            overlayControllers.first(where: { $0.screenID == screenID })?.setActiveRecordingFrame(nil)
            activeRegionRecordingScreenID = nil
        }
        Task { @MainActor in
            await ScreenRecordingService.shared.stop()
            showToast("Recording Saved", systemImage: "video.fill")
        }
    }

    // MARK: - Delete

    /// Deletes the currently selected objects, or clears the entire canvas if
    /// nothing is selected. Called by the Delete key.
    func deleteSelected() {
        let ids = overlayControllers.reduce(into: Set<UUID>()) { $0.formUnion($1.canvasView.currentSelectedObjectIDs) }
        if !ids.isEmpty {
            for id in ids { document.remove(id: id) }
            overlayControllers.forEach { $0.canvasView.clearSelection() }
        } else {
            clearCanvas()
        }
    }

    /// Wipes every drawn object and announces it. Used by the trash button directly, and by
    /// `deleteSelected()` when nothing is selected (Delete with an empty selection means "clear
    /// everything"). Deleting a specific selection doesn't go through here — that's a much more
    /// targeted action than "clear the canvas" and doesn't need the same announcement.
    public func clearCanvas() {
        document.clear()
        showToast("Canvas Cleared", systemImage: "trash.fill")
    }
}
