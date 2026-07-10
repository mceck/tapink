import AppKit
import Combine
import SwiftUI

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
    public private(set) var isEditingText = false

    public let document = DrawingDocument()
    private lazy var autofade = AutofadeController(document: document)

    private var overlayControllers: [OverlayWindowController] = []
    private let toolbarController = ToolbarPanelController()
    private var screenObserver: NSObjectProtocol?
    private var previouslyActiveApp: NSRunningApplication?
    private var toolBeforeSpotlight: DrawingTool?

    public init() {
        toolbarController.coordinator = self
        toolState.color = AppSettings.shared.brushColor
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
        // stealing Cmd-Tab visibility, but it still needs Drawzee to actually be
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
        // here for shortcuts/text-entry to actually reach Drawzee.
        NSApp.activate(ignoringOtherApps: true)
        toolbarController.show(on: DrawSessionCoordinator.screenUnderCursor() ?? NSScreen.main, revealed: !isSidebarHidden)
        NSLog("Drawzee: enableDrawMode done, appActive=\(NSApp.isActive)")
    }

    public func disableDrawMode() {
        guard isDrawModeActive else { return }
        isDrawModeActive = false
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
            return
        }
        if tool == .spotlight {
            toolBeforeSpotlight = toolState.selectedTool
        }
        toolState.selectedTool = tool
    }

    public func setColor(_ color: NSColor) {
        toolState.color = color
        AppSettings.shared.brushColor = color
    }

    public func setLineWidth(_ width: CGFloat) {
        toolState.lineWidth = width
        AppSettings.shared.brushLineWidth = width
    }

    public func setShape(_ shape: ShapeKind) {
        toolState.selectedShape = shape
        toolState.selectedTool = .shape
    }

    // MARK: - Auto-fade

    /// Applies to objects committed from now on (a stroke already in progress
    /// counts: its fade clock starts at mouse-up, which lands after this).
    /// Turning it on also wipes whatever is already drawn: the mode means
    /// "nothing sticks around", so pre-existing permanent drawings would
    /// otherwise linger forever next to the self-erasing new ones.
    /// Toggling off leaves everything currently on screen permanent.
    public func toggleAutofade() {
        isAutofadeEnabled.toggle()
        if isAutofadeEnabled {
            document.clear()
        }
        autofade.setEnabled(isAutofadeEnabled)
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

    public func toggleFreezeBackground() {
        isBackgroundFrozen ? unfreezeBackground() : freezeBackground()
    }

    public func freezeBackground() {
        guard isDrawModeActive, !isBackgroundFrozen else { return }
        isBackgroundFrozen = true
        // Exclude every one of Drawzee's own windows (toolbar + every overlay canvas) so the
        // frozen backdrop is a clean shot of what's underneath — existing drawn objects stay
        // vector-only in `document` and keep replaying on top each frame, so undo/redo/clear
        // still work normally against a frozen background.
        let excludedWindowNumbers = [toolbarController.windowNumber] + overlayControllers.map(\.windowNumber)
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
        let excludedWindowNumbers = [toolbarController.windowNumber]
        Task {
            await ScreenshotService.shared.capture(
                displayID: displayID,
                excludingWindowNumbers: excludedWindowNumbers,
                saveToDisk: saveToDisk
            )
        }
    }

    // MARK: - Selected-area screenshot

    /// Puts every screen's canvas into crosshair drag-to-select mode. The user
    /// can start the drag on whichever monitor they want; the previously
    /// selected drawing tool is left untouched and resumes once the selection
    /// is made (or cancelled).
    public func beginRegionScreenshotSelection() {
        guard isDrawModeActive, !isSelectingRegion else { return }
        isSelectingRegion = true
        overlayControllers.forEach { $0.setRegionSelectionActive(true) }
    }

    public func cancelRegionSelection() {
        guard isSelectingRegion else { return }
        isSelectingRegion = false
        overlayControllers.forEach { $0.setRegionSelectionActive(false) }
    }

    /// Called by whichever screen's `CanvasView` the drag actually happened on.
    /// `rectInPoints` is in that screen's own view-local coordinates (origin at
    /// its bottom-left, matching `NSScreen.frame`'s size), which is exactly what
    /// `ScreenshotService` needs to convert into a pixel crop rect.
    func completeRegionScreenshot(screenID: ScreenID, rectInPoints: CGRect) {
        isSelectingRegion = false
        overlayControllers.forEach { $0.setRegionSelectionActive(false) }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == screenID }) else { return }
        let excludedWindowNumbers = [toolbarController.windowNumber]
        let saveToDisk = AppSettings.shared.regionScreenshotDestination == .file
        Task {
            await ScreenshotService.shared.captureRegion(
                displayID: screenID,
                regionInPoints: rectInPoints,
                scale: screen.backingScaleFactor,
                excludingWindowNumbers: excludedWindowNumbers,
                saveToDisk: saveToDisk
            )
        }
    }
}
