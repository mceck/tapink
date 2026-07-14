import AppKit

public enum ScreenshotDestination: String, Codable, CaseIterable {
    case clipboard
    case file

    public var displayName: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .file: return "Pictures Folder"
        }
    }
}

public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let hideFromDock = "hideFromDockAndSwitcher"
        static let screenshotFolder = "screenshotSaveFolderPath"
        static let regionScreenshotDestination = "regionScreenshotDestination"
        static let shortcuts = "shortcutBindingsOverride"
        static let brushColor = "brushColorComponents"
        static let brushLineWidth = "brushLineWidth"
        static let autofadeDelay = "autofadeDelaySeconds"
        static let startWithSidebarHidden = "startDrawModeWithSidebarHidden"
        static let recordCursor = "recordCursorInVideos"
        static let maxRecordingDuration = "maxRecordingDurationMinutes"
    }

    /// Called whenever `hideFromDockAndSwitcher` changes, so the app delegate can
    /// apply the new NSApplication activation policy live.
    public var onHideFromDockChanged: ((Bool) -> Void)?

    private var overrides: [String: ShortcutBinding] = [:]

    private init() {
        defaults.register(defaults: [Keys.hideFromDock: true])
        loadShortcutOverrides()
    }

    public var hideFromDockAndSwitcher: Bool {
        get { defaults.bool(forKey: Keys.hideFromDock) }
        set {
            defaults.set(newValue, forKey: Keys.hideFromDock)
            onHideFromDockChanged?(newValue)
        }
    }

    public static var defaultScreenshotFolder: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Pictures/TapInk")
    }

    public var screenshotSaveFolderPath: String {
        get { defaults.string(forKey: Keys.screenshotFolder) ?? AppSettings.defaultScreenshotFolder }
        set { defaults.set(newValue, forKey: Keys.screenshotFolder) }
    }

    /// Where a selected-area screenshot goes; full-screen ⌘C/⌘S always mean
    /// clipboard/disk respectively regardless of this setting.
    public var regionScreenshotDestination: ScreenshotDestination {
        get {
            ScreenshotDestination(rawValue: defaults.string(forKey: Keys.regionScreenshotDestination) ?? "") ?? .clipboard
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.regionScreenshotDestination) }
    }

    /// Stored as sRGB components rather than an archived `NSColor` so a plain,
    /// inspectable `[Double]` round-trips reliably regardless of which dynamic
    /// system color (if any) was selected — the picker already lets users land
    /// on arbitrary custom colors, so freezing to a static RGBA value on
    /// restore matches existing behavior.
    public var brushColor: NSColor {
        get {
            guard let components = defaults.array(forKey: Keys.brushColor) as? [Double], components.count == 4 else {
                return .systemYellow
            }
            return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components[3])
        }
        set {
            let rgba = newValue.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
            defaults.set(
                [Double(rgba.redComponent), Double(rgba.greenComponent), Double(rgba.blueComponent), Double(rgba.alphaComponent)],
                forKey: Keys.brushColor
            )
        }
    }

    /// How long a drawing stays on screen after commit before its auto-fade
    /// erase animation starts. Read at commit time, so changing it never
    /// retroactively reschedules objects already waiting to fade.
    public var autofadeDelaySeconds: TimeInterval {
        get {
            let stored = defaults.double(forKey: Keys.autofadeDelay)
            return stored > 0 ? stored : 1
        }
        set { defaults.set(newValue, forKey: Keys.autofadeDelay) }
    }

    /// Whether a fresh draw-mode session starts with the toolbar already fully
    /// hidden (see `DrawSessionCoordinator.toggleSidebarHidden()`). Defaults to
    /// off, since a new session with no visible toolbar at all would leave a
    /// first-time user with no obvious way to reach any tool.
    public var startDrawModeWithSidebarHidden: Bool {
        get { defaults.bool(forKey: Keys.startWithSidebarHidden) }
        set { defaults.set(newValue, forKey: Keys.startWithSidebarHidden) }
    }

    /// Whether the mouse cursor is captured in screen recordings. Defaults to on — a
    /// recording is closer to a tutorial/walkthrough where seeing the pointer matters,
    /// unlike screenshots which deliberately hide it (`ScreenshotService` always sets
    /// `showsCursor = false`). Uses `object(forKey:)` rather than `bool(forKey:)` since
    /// the latter can't distinguish "never set" from "explicitly set to false", and the
    /// default here needs to be `true`.
    public var recordCursorInVideos: Bool {
        get { defaults.object(forKey: Keys.recordCursor) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.recordCursor) }
    }

    /// A recording keeps running independent of draw mode now (Esc/exiting draw mode no
    /// longer stops it), so this is the backstop that eventually ends it on its own if the
    /// user forgets — read once at recording start (see `DrawSessionCoordinator
    /// .scheduleRecordingTimeout`), not re-read live while a recording is already in flight.
    public var maxRecordingDurationMinutes: TimeInterval {
        get {
            let stored = defaults.double(forKey: Keys.maxRecordingDuration)
            return stored > 0 ? stored : 30
        }
        set { defaults.set(newValue, forKey: Keys.maxRecordingDuration) }
    }

    public var brushLineWidth: CGFloat {
        get {
            let stored = defaults.double(forKey: Keys.brushLineWidth)
            return stored > 0 ? CGFloat(stored) : 4
        }
        set { defaults.set(Double(newValue), forKey: Keys.brushLineWidth) }
    }

    private func loadShortcutOverrides() {
        guard let data = defaults.data(forKey: Keys.shortcuts),
              let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else { return }
        overrides = decoded
    }

    private func saveShortcutOverrides() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: Keys.shortcuts)
    }

    public func binding(for action: ShortcutAction) -> ShortcutBinding {
        overrides[action.rawValue] ?? ShortcutBinding.defaults[action]!
    }

    public func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        overrides[action.rawValue] = binding
        saveShortcutOverrides()
        NotificationCenter.default.post(name: .tapinkShortcutsChanged, object: nil)
    }

    public func resetBinding(for action: ShortcutAction) {
        overrides.removeValue(forKey: action.rawValue)
        saveShortcutOverrides()
        NotificationCenter.default.post(name: .tapinkShortcutsChanged, object: nil)
    }
}

public extension Notification.Name {
    static let tapinkShortcutsChanged = Notification.Name("tapinkShortcutsChanged")
}
