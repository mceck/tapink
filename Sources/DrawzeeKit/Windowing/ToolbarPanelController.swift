import AppKit
import SwiftUI

/// The single draggable tool sidebar. It is a `.nonactivatingPanel` so it can
/// become key (needed for its own controls and for tool-shortcut keystrokes)
/// without activating Drawzee as the frontmost application, and sits one level
/// above the per-screen canvas panels so its clicks never leak through to the
/// canvas beneath it.
public final class ToolbarPanelController: NSObject {
    public weak var coordinator: DrawSessionCoordinator?

    private let panel: NSPanel
    private var hostingView: NSView?

    public override init() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 68, height: 620),
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

    public func show(on screen: NSScreen?) {
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
        panel.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        panel.orderOut(nil)
    }

    /// Restores key status to the toolbar after a canvas panel borrowed it for
    /// text editing (only meaningful while the toolbar is still on screen).
    public func reclaimKey() {
        guard panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    public var windowNumber: Int { panel.windowNumber }
}
