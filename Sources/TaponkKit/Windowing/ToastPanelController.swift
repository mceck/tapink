import AppKit
import SwiftUI

/// A brief, unobtrusive HUD notification ("Draw Mode On", a tool's name, ...) shown near the
/// bottom of whichever screen currently hosts the toolbar, then fades away on its own. Kept as
/// its own panel rather than routed through `ToolbarPanelController` since it must never take
/// key status or intercept clicks, and must be excluded from screenshots/recordings the same way
/// the toolbar is (see `windowNumber`).
public final class ToastPanelController: NSObject {
    private static let visibleDuration: TimeInterval = 0.6
    private static let fadeInDuration: TimeInterval = 0.12
    private static let fadeOutDuration: TimeInterval = 0.3
    /// Distance from the bottom edge of the screen's full frame (not `visibleFrame`) — the
    /// overlay canvases already draw over the whole display including the Dock area, so this
    /// stays consistent with that rather than shifting depending on Dock visibility.
    private static let bottomMargin: CGFloat = 64

    private let panel: NSPanel
    private var hostingView: NSHostingView<ToastView>?
    private var dismissWorkItem: DispatchWorkItem?

    public override init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        self.panel = panel
        super.init()
    }

    /// Shows (or replaces) the toast on `screen`, resetting its auto-dismiss timer. A no-op if
    /// there's no screen to show it on (e.g. the toolbar hasn't been placed on one yet).
    public func show(message: String, systemImage: String, on screen: NSScreen?) {
        guard let screen else { return }
        dismissWorkItem?.cancel()

        let hosting: NSHostingView<ToastView>
        if let existing = hostingView {
            existing.rootView = ToastView(message: message, systemImage: systemImage)
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: ToastView(message: message, systemImage: systemImage))
            panel.contentView = hosting
            hostingView = hosting
        }
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + Self.bottomMargin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeOutDuration
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                self.panel.orderOut(nil)
            }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: workItem)
    }

    public var windowNumber: Int { panel.windowNumber }
}
