import SwiftUI
import AppKit

struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Required for the ⌥Tab shortcut that opens draw mode.",
                    isGranted: permissions.isAccessibilityGranted,
                    grant: permissions.requestAccessibility
                )
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Required to capture screenshots.",
                    isGranted: permissions.isScreenRecordingGranted,
                    grant: permissions.requestScreenRecording
                )
            }
            Section("General") {
                Toggle("Start at Login", isOn: $model.startAtLogin)
                Toggle("Hide from Dock and App Switcher", isOn: $model.hideFromDock)
            }
            Section("Drawing") {
                Stepper(value: $model.autofadeDelay, in: 1...30, step: 1) {
                    HStack {
                        Text("Auto-fade drawings after")
                        Spacer()
                        Text("\(Int(model.autofadeDelay)) s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Toggle("Start draw mode with sidebar hidden", isOn: $model.startWithSidebarHidden)
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
        .frame(width: 480, height: 600)
        .onAppear { permissions.refresh() }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let grant: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant…", action: grant)
            }
        }
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
    @Published var autofadeDelay: Double {
        didSet { AppSettings.shared.autofadeDelaySeconds = autofadeDelay }
    }
    @Published var startWithSidebarHidden: Bool {
        didSet { AppSettings.shared.startDrawModeWithSidebarHidden = startWithSidebarHidden }
    }

    init() {
        startAtLogin = LoginItemManager.shared.isEnabled
        hideFromDock = AppSettings.shared.hideFromDockAndSwitcher
        screenshotFolder = AppSettings.shared.screenshotSaveFolderPath
        regionScreenshotDestination = AppSettings.shared.regionScreenshotDestination
        autofadeDelay = AppSettings.shared.autofadeDelaySeconds
        startWithSidebarHidden = AppSettings.shared.startDrawModeWithSidebarHidden
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
