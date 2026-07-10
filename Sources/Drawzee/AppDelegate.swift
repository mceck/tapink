import AppKit
import ApplicationServices
import CoreGraphics
import DrawzeeKit

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var coordinator: DrawSessionCoordinator!
    private var statusItemController: StatusItemController!
    private var hotkeyManager: HotkeyManager!
    private var accessibilityGrantPoller: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Avoids a Dock-icon flash before the persisted policy is applied below.
        NSApp.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = DrawSessionCoordinator()
        statusItemController = StatusItemController(coordinator: coordinator)
        hotkeyManager = HotkeyManager(coordinator: coordinator)

        applyDockPolicy(hidden: AppSettings.shared.hideFromDockAndSwitcher)
        AppSettings.shared.onHideFromDockChanged = { [weak self] hidden in
            self?.applyDockPolicy(hidden: hidden)
        }

        requestPermissionsIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func applyDockPolicy(hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        if !hidden {
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// The two permission prompts must not fire in the same runloop tick: on a
    /// fresh install, requesting Accessibility and Screen Recording
    /// back-to-back makes macOS show only the Accessibility dialog, and the
    /// Screen Recording request is dropped without ever registering the app in
    /// that pane's list. So: ask for Accessibility first, poll until it's
    /// actually granted (there is no grant notification/callback API), then
    /// install the activation event tap — it can't be created without trust,
    /// and creating it now is what makes the ⌥Tab shortcut work immediately
    /// instead of only after a relaunch — and only at that point move on to
    /// the Screen Recording request.
    @MainActor
    private func requestPermissionsIfNeeded() {
        if AXIsProcessTrusted() {
            requestScreenRecordingIfNeeded()
            return
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        // Also catches a grant triggered later from the Settings window's
        // "Grant…" button, since the poller keeps running until trust appears.
        accessibilityGrantPoller = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            // Timers scheduled on the main runloop always fire on the main
            // thread; assumeIsolated just tells the compiler so.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.accessibilityGrantPoller = nil
                self.hotkeyManager.installActivationTapIfNeeded()
                PermissionsManager.shared.refresh()
                self.requestScreenRecordingIfNeeded()
            }
        }
    }

    @MainActor
    private func requestScreenRecordingIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        // The system prompt has its own "Open System Settings" button, so
        // unlike the Settings-window path this doesn't also deep-link to the
        // pane.
        PermissionsManager.shared.promptScreenRecordingAndRegister()
    }
}
