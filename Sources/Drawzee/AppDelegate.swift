import AppKit
import ApplicationServices
import CoreGraphics
import DrawzeeKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: DrawSessionCoordinator!
    private var statusItemController: StatusItemController!
    private var hotkeyManager: HotkeyManager!

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

    private func requestPermissionsIfNeeded() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
    }
}
