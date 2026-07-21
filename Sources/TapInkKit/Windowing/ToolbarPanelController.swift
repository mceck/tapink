import AppKit
import QuartzCore
import SwiftUI

/// The single draggable tool sidebar. It is a `.nonactivatingPanel` so it can
/// become key (needed for its own controls and for tool-shortcut keystrokes)
/// without activating TapInk as the frontmost application, and sits one level
/// above the per-screen canvas panels so its clicks never leak through to the
/// canvas beneath it.
public final class ToolbarPanelController: NSObject {
    public weak var coordinator: DrawSessionCoordinator?

    private let panel: NSPanel
    private var hostingView: NSView?

    /// Full height showing every tool/action button; tuned by hand to match
    /// `ToolbarView`'s expanded content exactly (no dead draggable space below it).
    private let expandedHeight: CGFloat = 620
    /// Collapsed height showing the color swatch, the selected-tool indicator, and the
    /// collapse toggle; same tuning approach as `expandedHeight`, sized for a 24pt swatch
    /// and two 32pt buttons.
    private let collapsedHeight: CGFloat = 144

    public override init() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 620),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        self.panel = panel
        super.init()
    }

    /// `revealed: false` (for `DrawSessionCoordinator.enableDrawMode()` when the
    /// user has set the "start with sidebar hidden" preference) still creates the
    /// hosting view and positions the panel, just skips ever ordering it front —
    /// ordering it front and then immediately back out via `setFullyHidden(true)`
    /// visibly flashed the toolbar on screen for a frame before this existed.
    public func show(on screen: NSScreen?, revealed: Bool = true) {
        guard let coordinator else { return }
        if hostingView == nil {
            let hosting = NSHostingView(rootView: ToolbarView(coordinator: coordinator))
            panel.contentView = hosting
            hostingView = hosting
        }
        if let screen {
            let origin = CGPoint(x: screen.frame.minX + 28, y: screen.frame.midY - panel.frame.height / 2)
            panel.setFrameOrigin(origin)
        }
        guard revealed else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        panel.orderOut(nil)
    }

    /// Toggled by `DrawSessionCoordinator.toggleSidebarHidden()` — unlike `hide()`
    /// (only used when draw mode itself is exiting) or `show(on:)` (only used once
    /// per session, to reset the toolbar to a predictable spot), this is invoked
    /// repeatedly mid-session and must never touch the panel's size or position, so
    /// it reappears exactly where the user left it (possibly dragged elsewhere).
    public func setFullyHidden(_ hidden: Bool) {
        if hidden {
            hide()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Resizes the panel keeping its top edge fixed, so collapsing/expanding only
    /// grows or shrinks it downward instead of shifting the whole toolbar (and the
    /// color swatch anchored at its top) up or down on screen. Uses an explicit,
    /// short duration (rather than the legacy `animate: true` heuristic) so callers
    /// can rely on it finishing before `DrawSessionCoordinator`'s content-fade delay.
    ///
    /// `animated: false` is for `DrawSessionCoordinator.enableDrawMode()`: draw mode
    /// always starts expanded regardless of how a *previous* session was left, and
    /// that reset must land before the panel is ever ordered on screen — animating it
    /// there would show the panel popping in mid-resize instead of already at its
    /// final size and position.
    public func setCollapsed(_ collapsed: Bool, animated: Bool = true) {
        let newHeight = collapsed ? collapsedHeight : expandedHeight
        var frame = panel.frame
        guard frame.height != newHeight else { return }
        let top = frame.maxY
        frame.size.height = newHeight
        frame.origin.y = top - newHeight
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Restores key status to the toolbar after a canvas panel borrowed it for
    /// text editing (only meaningful while the toolbar is still on screen).
    public func reclaimKey() {
        guard panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    public var windowNumber: Int { panel.windowNumber }

    /// Whichever screen the toolbar is currently positioned on (it can be dragged between
    /// monitors), used to place the toast HUD alongside it.
    public var currentScreen: NSScreen? { panel.screen }

    /// The toolbar panel's current on-screen frame, used by `TooltipPanelController` to decide
    /// which side of the sidebar has more free room.
    public var frameOnScreen: NSRect { panel.frame }

    /// Converts a rect in the panel's own (window-base) coordinate system — as reported by
    /// `NSView.convert(_:to: nil)` — to screen coordinates, for positioning a hover tooltip
    /// beside whichever button reported its frame this way.
    public func screenFrame(forWindowLocalRect rect: NSRect) -> NSRect {
        panel.convertToScreen(rect)
    }
}
