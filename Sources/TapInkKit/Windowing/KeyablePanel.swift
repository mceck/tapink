import AppKit

/// A `.borderless` `.nonactivatingPanel` cannot become key by AppKit's default rule
/// (`canBecomeKey` requires `.titled` unless overridden) — without this override,
/// `makeKeyAndOrderFront` silently orders the panel to the front but never actually
/// grants it key status, so typed keystrokes have no window to route to and vanish
/// before reaching any first responder. This is why the text tool accepted clicks
/// but not typing: the overlay panel only ever looked frontmost, never truly key.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
