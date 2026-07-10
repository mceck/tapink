import AppKit

/// Two-tier shortcut handling:
///
/// - A persistent **global** monitor (`NSEvent.addGlobalMonitorForEvents`) handles
///   draw-mode activation, since it must fire even when no Drawzee window exists
///   yet. This requires Accessibility trust and does not consume the keystroke
///   (harmless here — the default ⌥Tab binding has no OS-level meaning).
/// - A **local** monitor (`NSEvent.addLocalMonitorForEvents`) handles everything
///   else, only while draw mode is already active. Returning `nil` from it
///   consumes the event so it doesn't also reach the app underneath (e.g. ⌘C
///   shouldn't also trigger "Copy" in whatever's behind the overlay).
public final class HotkeyManager {
    private weak var coordinator: DrawSessionCoordinator?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init(coordinator: DrawSessionCoordinator) {
        self.coordinator = coordinator
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleGlobal(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.handleLocal(event) else { return event }
            return nil
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func handleGlobal(_ event: NSEvent) {
        guard let coordinator, !coordinator.isDrawModeActive else { return }
        guard AppSettings.shared.binding(for: .activateDrawMode).matches(event) else { return }
        NSLog("Drawzee: global monitor matched activateDrawMode, appActive=\(NSApp.isActive)")
        // Activating synchronously, in direct response to the triggering key
        // event, matters: macOS is far more willing to actually hand over
        // keyboard focus to a background accessory app when the activation
        // request is the immediate result of user input rather than a
        // dispatched callback a runloop turn later.
        coordinator.enableDrawMode()
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
            (.copyScreenshot, { coordinator.captureScreenshot(saveToDisk: false) }),
            (.saveScreenshot, { coordinator.captureScreenshot(saveToDisk: true) }),
            (.regionScreenshot, { coordinator.beginRegionScreenshotSelection() }),
            (.freezeBackground, { coordinator.toggleFreezeBackground() }),
            (.redo, { coordinator.document.redo() }),
            (.undo, { coordinator.document.undo() }),
            (.clearCanvas, { coordinator.document.clear() }),
            (.toolPen, { coordinator.selectTool(.pen) }),
            (.toolHighlighter, { coordinator.selectTool(.highlighter) }),
            (.toolShape, { coordinator.selectTool(.shape) }),
            (.toolSpotlight, { coordinator.selectTool(.spotlight) }),
            (.toolText, { coordinator.selectTool(.text) }),
        ]

        for (action, handler) in actions where settings.binding(for: action).matches(event) {
            handler()
            return true
        }
        return false
    }
}
