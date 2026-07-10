import AppKit
import Combine

/// One borderless, transparent panel per connected NSScreen. It sits above
/// full-screen apps and every Space (`.screenSaver` level + the collection
/// behavior below), and is a `.nonactivatingPanel` so it never steals the
/// frontmost-application identity from whatever the user is drawing over.
///
/// Mouse routing in AppKit depends only on which window is topmost at the
/// click location, not on key/first-responder status, so this panel can be
/// fully mouse-interactive without ever becoming key — keyboard focus stays
/// with the toolbar (or with a canvas's text field during text editing).
public final class OverlayWindowController: NSObject {
    public let screenID: ScreenID
    public let canvasView: CanvasView

    private let panel: NSPanel
    private weak var coordinator: DrawSessionCoordinator?
    private var cancellable: AnyCancellable?

    public init(screen: NSScreen, document: DrawingDocument, coordinator: DrawSessionCoordinator) {
        self.screenID = screen.displayID ?? 0
        self.coordinator = coordinator

        let panel = KeyablePanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        self.panel = panel

        let canvas = CanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.autoresizingMask = [.width, .height]
        panel.contentView = canvas
        self.canvasView = canvas

        super.init()

        canvas.screenID = screenID
        canvas.document = document
        canvas.toolProvider = { [weak coordinator] in coordinator?.toolState ?? ToolState() }
        canvas.fadeProgressProvider = { [weak coordinator] id in coordinator?.fadeProgress(for: id) }
        canvas.onTextEditingBegin = { [weak coordinator] in coordinator?.beginTextEditing() }
        canvas.onTextEditingEnd = { [weak coordinator] in coordinator?.endTextEditing() }
        canvas.onRegionSelected = { [weak coordinator, screenID] rect in
            coordinator?.completeRegionScreenshot(screenID: screenID, rectInPoints: rect)
        }

        cancellable = coordinator.$toolState
            .sink { [weak canvas] state in
                if state.selectedTool != .spotlight {
                    canvas?.clearSpotlight()
                }
            }
    }

    public func updateFrameIfNeeded() {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == screenID }), panel.frame != screen.frame else { return }
        panel.setFrame(screen.frame, display: true)
    }

    public func showForDrawing() {
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
        panel.ignoresMouseEvents = true
    }

    public func setCanvasHidden(_ hidden: Bool) {
        canvasView.isHidden = hidden
        panel.ignoresMouseEvents = hidden
    }

    public func cancelTextEditing() {
        canvasView.cancelTextEditing()
    }

    public func setRegionSelectionActive(_ active: Bool) {
        canvasView.setRegionSelectionActive(active)
    }

    public func setFrozenBackground(_ image: NSImage?) {
        canvasView.setFrozenBackground(image)
    }

    public var windowNumber: Int { panel.windowNumber }
}
