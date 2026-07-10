import SwiftUI
import AppKit

struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start at Login", isOn: $model.startAtLogin)
                Toggle("Hide from Dock and App Switcher", isOn: $model.hideFromDock)
            }
            Section("Screenshots") {
                HStack {
                    Text(model.screenshotFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { model.chooseFolder() }
                }
                Picker("Selected-area screenshots go to", selection: $model.regionScreenshotDestination) {
                    ForEach(ScreenshotDestination.allCases, id: \.self) { destination in
                        Text(destination.displayName).tag(destination)
                    }
                }
            }
            Section("Shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(action: action)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var startAtLogin: Bool {
        didSet { LoginItemManager.shared.setEnabled(startAtLogin) }
    }
    @Published var hideFromDock: Bool {
        didSet { AppSettings.shared.hideFromDockAndSwitcher = hideFromDock }
    }
    @Published var screenshotFolder: String
    @Published var regionScreenshotDestination: ScreenshotDestination {
        didSet { AppSettings.shared.regionScreenshotDestination = regionScreenshotDestination }
    }

    init() {
        startAtLogin = LoginItemManager.shared.isEnabled
        hideFromDock = AppSettings.shared.hideFromDockAndSwitcher
        screenshotFolder = AppSettings.shared.screenshotSaveFolderPath
        regionScreenshotDestination = AppSettings.shared.regionScreenshotDestination
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: screenshotFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        screenshotFolder = url.path
        AppSettings.shared.screenshotSaveFolderPath = url.path
    }
}
