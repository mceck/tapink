import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Live status of the two system permissions Drawzee needs — Accessibility
/// for the global ⌥Tab shortcut, Screen Recording for screenshots — plus the
/// actions to (re)request them. Used by `SettingsView` to show a "Grant…"
/// button instead of leaving the user to guess why something silently isn't
/// working. `AppDelegate` still owns the at-launch request sequence (see its
/// doc comment on why the two system prompts can't fire in the same runloop
/// tick); this is the on-demand path the user can trigger from the UI at any
/// point afterwards, including to fix a permission they previously denied.
@MainActor
public final class PermissionsManager: ObservableObject {
    public static let shared = PermissionsManager()

    @Published public private(set) var isAccessibilityGranted: Bool
    @Published public private(set) var isScreenRecordingGranted: Bool

    private init() {
        isAccessibilityGranted = AXIsProcessTrusted()
        isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
        // Permission state only ever changes while the user is away in System
        // Settings, so re-check whenever the app comes back to the foreground
        // rather than only once at launch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    public func refresh() {
        isAccessibilityGranted = AXIsProcessTrusted()
        isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    /// Prompts for Accessibility if it's never been decided; if the user
    /// already denied it, `AXIsProcessTrustedWithOptions` won't re-prompt, so
    /// this also deep-links straight to the right System Settings pane.
    public func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        openSystemSettingsPane("Privacy_Accessibility")
    }

    public func requestScreenRecording() {
        promptScreenRecordingAndRegister()
        openSystemSettingsPane("Privacy_ScreenCapture")
    }

    /// Fires the system Screen Recording prompt (if the user hasn't decided
    /// yet) and — crucially — runs a ScreenCaptureKit content enumeration.
    /// `CGRequestScreenCaptureAccess()` alone doesn't reliably register the
    /// app in the Screen Recording pane's list, so the user landed on a pane
    /// without Drawzee in it and had to add the app manually via "+"; an
    /// actual SCK query is what creates the TCC entry that makes the row show
    /// up pre-inserted. The enumeration result is intentionally discarded —
    /// the call exists purely for that side effect.
    public func promptScreenRecordingAndRegister() {
        _ = CGRequestScreenCaptureAccess()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, _ in }
    }

    private func openSystemSettingsPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
