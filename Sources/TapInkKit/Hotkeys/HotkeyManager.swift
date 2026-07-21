import AppKit
import CoreGraphics

/// Two-tier shortcut handling:
///
/// - A persistent **global** intercept handles draw-mode activation, since it
///   must fire even when no TapInk window exists yet. This is a `CGEventTap`,
///   not a plain `NSEvent.addGlobalMonitorForEvents` monitor: a global monitor
///   can only *observe* the keystroke, it can't consume it, so the previously-
///   frontmost app (a text editor, a browser) still received the raw Tab key
///   and acted on it — inserting a tab character, or shifting focus/scroll to
///   the next page element. Only an event tap placed ahead of the app can
///   actually swallow the event before it gets there. Requires the same
///   Accessibility trust the app already requests in
///   `AppDelegate.requestPermissionsIfNeeded` (both mechanisms need it for
///   key events, tap or not).
/// - A **local** monitor (`NSEvent.addLocalMonitorForEvents`) handles everything
///   else, only while draw mode is already active. Returning `nil` from it
///   consumes the event so it doesn't also reach the app underneath (e.g. ⌘C
///   shouldn't also trigger "Copy" in whatever's behind the overlay).
public final class HotkeyManager {
    private weak var coordinator: DrawSessionCoordinator?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var flagsMonitor: Any?
    /// Mirrors whether `DrawSessionCoordinator.beginTemporaryMoveTool()` is currently in effect,
    /// so `handleFlagsChanged` only calls begin/end on an actual transition rather than on every
    /// `flagsChanged` event (which fires for unrelated modifiers too, e.g. Shift).
    private var isTemporaryMoveActive = false

    public init(coordinator: DrawSessionCoordinator) {
        self.coordinator = coordinator
        installActivationEventTap()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.handleLocal(event) else { return event }
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    deinit {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }

    /// Retries creating the activation event tap. Tap creation fails outright
    /// while the app isn't Accessibility-trusted, and nothing system-side
    /// retries it once trust is granted — without this hook the activation
    /// shortcut stayed dead until relaunch even after the user flipped the
    /// toggle in System Settings. `AppDelegate` calls it the moment trust
    /// appears. No-op once the tap exists.
    public func installActivationTapIfNeeded() {
        guard eventTap == nil else { return }
        installActivationEventTap()
    }

    private func installActivationEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, userInfo in
                guard let userInfo else { return Unmanaged.passRetained(cgEvent) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleTap(type: type, cgEvent: cgEvent)
            },
            userInfo: selfPtr
        ) else {
            NSLog("TapInk: failed to create event tap for draw-mode activation (Accessibility permission missing?)")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleTap(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that's too slow to respond, or when the
        // user re-toggles Accessibility permissions; re-enable so activation
        // doesn't silently go dead until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passRetained(cgEvent)
        }
        guard let coordinator,
              let nsEvent = NSEvent(cgEvent: cgEvent),
              AppSettings.shared.binding(for: .activateDrawMode).matches(nsEvent)
        else {
            return Unmanaged.passRetained(cgEvent)
        }
        NSLog("TapInk: event tap matched activateDrawMode, appActive=\(NSApp.isActive)")
        // Activating synchronously, in direct response to the triggering key
        // event, matters: macOS is far more willing to actually hand over
        // keyboard focus to a background accessory app when the activation
        // request is the immediate result of user input rather than a
        // dispatched callback a runloop turn later. Toggling (rather than only
        // ever enabling) lets the same shortcut also close draw mode, same as
        // pressing Esc.
        coordinator.toggleDrawMode()
        // Swallow it — without this, the frontmost app still receives the raw
        // Tab keystroke (see the doc comment above).
        return nil
    }

    /// Returns `true` if the event was handled (and should be swallowed).
    private func handleLocal(_ event: NSEvent) -> Bool {
        guard let coordinator, coordinator.isDrawModeActive else { return false }
        let settings = AppSettings.shared
        NSLog("TapInk: local monitor saw keyCode=\(event.keyCode) modifiers=\(event.modifierFlags.rawValue) isEditingText=\(coordinator.isEditingText) appActive=\(NSApp.isActive)")

        if coordinator.isEditingText {
            if settings.binding(for: .exitDrawMode).matches(event) {
                coordinator.cancelTextEditing()
                return true
            }
            return false
        }

        if coordinator.isSelectingRegion {
            if settings.binding(for: .exitDrawMode).matches(event) {
                coordinator.cancelRegionSelection()
            }
            // Swallow everything else so a stray tool-select shortcut can't
            // interrupt an in-progress drag-select.
            return true
        }

        let actions: [(ShortcutAction, () -> Void)] = [
            (.exitDrawMode, {
                if coordinator.toolState.selectedTool == .spotlight {
                    coordinator.selectTool(.spotlight)
                } else {
                    coordinator.disableDrawMode()
                }
            }),
            (.hideCanvas, { coordinator.toggleHideCanvas() }),
            (.toggleSidebar, { coordinator.toggleSidebarCollapsed() }),
            (.hideSidebar, { coordinator.toggleSidebarHidden() }),
            (.copyScreenshot, { coordinator.captureScreenshot(saveToDisk: false) }),
            (.saveScreenshot, { coordinator.captureScreenshot(saveToDisk: true) }),
            (.regionScreenshot, { coordinator.beginRegionScreenshotSelection() }),
            (.recordScreen, { coordinator.toggleScreenRecording() }),
            (.regionRecording, { coordinator.toggleRegionRecording() }),
            (.freezeBackground, { coordinator.toggleFreezeBackground() }),
            (.toggleAutofade, { coordinator.toggleAutofade() }),
            (.nextColor, { coordinator.selectNextColor() }),
            (.redo, { coordinator.document.redo() }),
            (.undo, { coordinator.document.undo() }),
            (.clearCanvas, { coordinator.deleteSelected() }),
            (.toolPen, { coordinator.selectTool(.pen) }),
            (.toolHighlighter, { coordinator.selectTool(.highlighter) }),
            (.shapeRectangle, { coordinator.setShape(.rectangle) }),
            (.shapeEllipse, { coordinator.setShape(.ellipse) }),
            (.shapeLine, { coordinator.setShape(.line) }),
            (.shapeArrow, { coordinator.setShape(.arrow) }),
            (.toolSpotlight, { coordinator.selectTool(.spotlight) }),
            (.toolText, { coordinator.selectTool(.text) }),
            (.toolMove, { coordinator.selectTool(.move) }),
            (.toolEraser, { coordinator.selectTool(.eraser) }),
        ]

        for (action, handler) in actions where shortcutMatches(action, event: event, settings: settings) {
            handler()
            return true
        }
        return false
    }

    /// Same as `settings.binding(for:).matches(event)`, except `.clearCanvas` (Delete) also
    /// matches while the "hold to temporarily switch to Move" gesture is active and the only
    /// extra modifier present is the one driving that hold. Delete's default binding requires no
    /// modifiers at all, so without this it could never fire while holding the modifier down —
    /// and deleting the selection right after nudging it, without letting go first, is exactly
    /// the point of the gesture.
    private func shortcutMatches(_ action: ShortcutAction, event: NSEvent, settings: AppSettings) -> Bool {
        let binding = settings.binding(for: action)
        if binding.matches(event) { return true }
        guard action == .clearCanvas, isTemporaryMoveActive, event.keyCode == binding.keyCode else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == settings.temporaryMoveToolModifier.eventModifierFlag
    }

    /// Drives the "hold ⌘ (or ⌥) to temporarily switch to Move" gesture: `flagsChanged` (not
    /// `keyDown`/`keyUp`, since modifier keys alone never generate those) fires on every press
    /// or release of any modifier, so this recomputes whether the hold *should* be active right
    /// now and only calls into the coordinator on an actual transition.
    private func handleFlagsChanged(_ event: NSEvent) {
        guard let coordinator else { return }
        guard coordinator.isDrawModeActive else {
            // Draw mode isn't active, so there's nothing to end — `DrawSessionCoordinator`
            // already resets its own side of this on `enableDrawMode()`/`disableDrawMode()`.
            // Just keep this flag in sync so the next session starts from a clean edge.
            isTemporaryMoveActive = false
            return
        }
        let shouldBeActive = !coordinator.isEditingText
            && !coordinator.isSelectingRegion
            && event.modifierFlags.contains(AppSettings.shared.temporaryMoveToolModifier.eventModifierFlag)
        guard shouldBeActive != isTemporaryMoveActive else { return }
        // Only *starting* the hold is guarded against an in-progress mouse drag — switching the
        // tool out from under an in-progress pen/shape stroke would leave it half-drawn. Ending
        // it always restores the previous tool immediately: skipping that when the mouse happens
        // to be down could otherwise leave the tool stuck on Move until some unrelated later
        // modifier change happens to re-evaluate it.
        if shouldBeActive, NSEvent.pressedMouseButtons != 0 { return }
        isTemporaryMoveActive = shouldBeActive
        if shouldBeActive {
            coordinator.beginTemporaryMoveTool()
        } else {
            coordinator.endTemporaryMoveTool()
        }
    }
}
