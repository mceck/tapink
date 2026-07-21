import AppKit
import SwiftUI

/// A small floating label shown just outside the toolbar's left or right edge — whichever side
/// has more free room on its current screen — while the user hovers a sidebar button. Kept as
/// its own panel (same reasoning as `ToastPanelController`) rather than a SwiftUI overlay inside
/// `ToolbarView`: the toolbar content is clipped to its rounded-rect shape, which would cut off
/// anything drawn past its own bounds, and a tooltip beside the sidebar needs to escape it.
public final class TooltipPanelController: NSObject {
    private static let gapFromToolbar: CGFloat = 4

    private let panel: NSPanel
    private var hostingView: NSHostingView<TooltipLabelView>?

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
        self.panel = panel
        super.init()
    }

    /// `buttonFrameOnScreen` is the hovered button's frame already converted to screen
    /// coordinates (see `ToolbarPanelController.screenFrame(forWindowLocalRect:)`);
    /// `toolbarFrameOnScreen` is only used to decide which side has more room and to keep the
    /// tooltip flush against the toolbar's edge regardless of which button is hovered.
    public func show(text: String, besideButtonAt buttonFrameOnScreen: NSRect, toolbarFrameOnScreen: NSRect, on screen: NSScreen?) {
        guard let screen else { return }
        let hosting: NSHostingView<TooltipLabelView>
        if let existing = hostingView {
            existing.rootView = TooltipLabelView(text: text)
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: TooltipLabelView(text: text))
            panel.contentView = hosting
            hostingView = hosting
        }
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let visible = screen.visibleFrame
        let spaceRight = visible.maxX - toolbarFrameOnScreen.maxX
        let spaceLeft = toolbarFrameOnScreen.minX - visible.minX
        let showOnRight = spaceRight >= spaceLeft
        let x = showOnRight
            ? toolbarFrameOnScreen.maxX + Self.gapFromToolbar
            : toolbarFrameOnScreen.minX - Self.gapFromToolbar - size.width
        let y = buttonFrameOnScreen.midY - size.height / 2
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
    }

    public var windowNumber: Int { panel.windowNumber }
}

private struct TooltipLabelView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .fixedSize()
    }
}
