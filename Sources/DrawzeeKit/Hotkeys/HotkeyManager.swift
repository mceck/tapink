import AppKit
import CoreGraphics

/// Two-tier shortcut handling:
///
/// - A persistent **global** intercept handles draw-mode activation, since it
///   must fire even when no Drawzee window exists yet. This is a `CGEventTap`,
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

    public init(coordinator: DrawSessionCoordinator) {
        self.coordinator = coordinator
        installActivationEventTap()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.handleLocal(event) else { return event }
            return nil
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
            NSLog("Drawzee: failed to create event tap for draw-mode activation (Accessibility permission missing?)")
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
        NSLog("Drawzee: event tap matched activateDrawMode, appActive=\(NSApp.isActive)")
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
        NSLog("Drawzee: local monitor saw keyCode=\(event.keyCode) modifiers=\(event.modifierFlags.rawValue) isEditingText=\(coordinator.isEditingText) appActive=\(NSApp.isActive)")

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
            (.exitDrawMode, { coordinator.disableDrawMode() }),
            (.hideCanvas, { coordinator.toggleHideCanvas() }),
            (.toggleSidebar, { coordinator.toggleSidebarCollapsed() }),
            (.hideSidebar, { coordinator.toggleSidebarHidden() }),
            (.copyScreenshot, { coordinator.captureScreenshot(saveToDisk: false) }),
            (.saveScreenshot, { coordinator.captureScreenshot(saveToDisk: true) }),
            (.regionScreenshot, { coordinator.beginRegionScreenshotSelection() }),
            (.freezeBackground, { coordinator.toggleFreezeBackground() }),
            (.toggleAutofade, { coordinator.toggleAutofade() }),
            (.redo, { coordinator.document.redo() }),
            (.undo, { coordinator.document.undo() }),
            (.clearCanvas, { coordinator.document.clear() }),
            (.toolPen, { coordinator.selectTool(.pen) }),
            (.toolHighlighter, { coordinator.selectTool(.highlighter) }),
            (.toolShape, { coordinator.selectTool(.shape) }),
            (.shapeRectangle, { coordinator.setShape(.rectangle) }),
            (.shapeEllipse, { coordinator.setShape(.ellipse) }),
            (.shapeLine, { coordinator.setShape(.line) }),
            (.shapeArrow, { coordinator.setShape(.arrow) }),
            (.toolSpotlight, { coordinator.selectTool(.spotlight) }),
            (.toolText, { coordinator.selectTool(.text) }),
            (.toolMove, { coordinator.selectTool(.move) }),
            (.toolEraser, { coordinator.selectTool(.eraser) }),
        ]

        for (action, handler) in actions where settings.binding(for: action).matches(event) {
            handler()
            return true
        }
        return false
    }
}
