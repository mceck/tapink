import AppKit
import Combine

public final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let coordinator: DrawSessionCoordinator
    private var toggleItem: NSMenuItem!
    /// The normal dropdown (draw-mode toggle, Settings, About, Quit). Swapped out for `nil`
    /// while a recording is active — see `updateIcon`.
    private var mainMenu: NSMenu!
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

        // A recording now outlives draw mode (see `DrawSessionCoordinator.disableDrawMode`), so
        // this doubles as how the user stops one once the toolbar/overlay is gone: the icon
        // turns into a plain red rec button — a single click stops the recording directly,
        // same "no dropdown to navigate" idea as `ToolbarView`'s capture button.
        coordinator.$isDrawModeActive
            .combineLatest(
                coordinator.$toolState.map(\.color).removeDuplicates(),
                coordinator.$activeRecordingKind.map { $0 != nil }.removeDuplicates()
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] active, color, isRecording in
                self?.updateIcon(active: active, color: color, isRecording: isRecording)
            }
            .store(in: &cancellables)
    }

    // `configureButton` sets the initial template image synchronously so the
    // status item never appears empty at launch; the Combine subscription above
    // (which delivers on the next run-loop pass) owns every update after that.
    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "TapInk")
        image?.isTemplate = true
        button.image = image
    }

    private func updateIcon(active: Bool, color: NSColor, isRecording: Bool) {
        guard let button = statusItem.button else { return }
        guard !isRecording else {
            // `statusItem.menu` being non-nil always wins over the button's own action on
            // click, so it has to come out entirely for a plain click to reach
            // `stopRecordingButtonPressed` instead of popping the dropdown.
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopRecordingButtonPressed)
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Stop Recording")
            let tinted = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            tinted?.isTemplate = false
            button.image = tinted
            return
        }
        statusItem.menu = mainMenu
        button.action = nil
        let image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "TapInk")
        if active {
            // While drawing, tint the icon with the current tool color. The
            // image must stop being a template, or the system re-renders it
            // monochrome and the palette color never shows.
            let tinted = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
            tinted?.isTemplate = false
            button.image = tinted
        } else {
            image?.isTemplate = true
            button.image = image
        }
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

        let aboutItem = NSMenuItem(title: "About TapInk", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit TapInk", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        mainMenu = menu
        statusItem.menu = menu
    }

    private func updateToggleTitle(active: Bool) {
        toggleItem.title = active ? "Disable Drawing Mode" : "Enable Drawing Mode"
        toggleItem.state = active ? .on : .off
    }

    @objc private func toggleDrawMode() {
        coordinator.toggleDrawMode()
    }

    @objc private func stopRecordingButtonPressed() {
        coordinator.stopRecording()
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
