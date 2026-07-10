import AppKit
import Combine

public final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let coordinator: DrawSessionCoordinator
    private var toggleItem: NSMenuItem!
    private var cancellables = Set<AnyCancellable>()

    public init(coordinator: DrawSessionCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        buildMenu()

        coordinator.$isDrawModeActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in self?.updateToggleTitle(active: active) }
            .store(in: &cancellables)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "Drawzee")
        image?.isTemplate = true
        button.image = image
    }

    private func buildMenu() {
        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Enable Drawing Mode", action: #selector(toggleDrawMode), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About Drawzee", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Drawzee", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateToggleTitle(active: Bool) {
        toggleItem.title = active ? "Disable Drawing Mode" : "Enable Drawing Mode"
        toggleItem.state = active ? .on : .off
    }

    @objc private func toggleDrawMode() {
        coordinator.toggleDrawMode()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openAbout() {
        AboutWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
