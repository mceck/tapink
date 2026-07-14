import XCTest
import AppKit
@testable import TapInkKit

final class AppSettingsTests: XCTestCase {
    // Mirrors AppSettings' own (private) UserDefaults key names, since the enum
    // itself isn't visible outside the declaring file even with @testable import.
    private let regionDestinationKey = "regionScreenshotDestination"
    private let screenshotFolderKey = "screenshotSaveFolderPath"
    private let hideFromDockKey = "hideFromDockAndSwitcher"
    private let maxRecordingDurationKey = "maxRecordingDurationMinutes"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "brushColorComponents")
        UserDefaults.standard.removeObject(forKey: "brushLineWidth")
        UserDefaults.standard.removeObject(forKey: regionDestinationKey)
        UserDefaults.standard.removeObject(forKey: screenshotFolderKey)
        UserDefaults.standard.removeObject(forKey: hideFromDockKey)
        UserDefaults.standard.removeObject(forKey: maxRecordingDurationKey)
        AppSettings.shared.onHideFromDockChanged = nil
        // Actions used by binding-related tests below; reset through the real API
        // (not a raw UserDefaults wipe) so the in-memory `overrides` cache the
        // singleton already loaded stays consistent with what's on disk.
        AppSettings.shared.resetBinding(for: .toolHighlighter)
        AppSettings.shared.resetBinding(for: .toolShape)
        super.tearDown()
    }

    func testBrushColorRoundTrips() {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        AppSettings.shared.brushColor = color
        let restored = AppSettings.shared.brushColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(restored.redComponent, 0.2, accuracy: 0.001)
        XCTAssertEqual(restored.greenComponent, 0.4, accuracy: 0.001)
        XCTAssertEqual(restored.blueComponent, 0.9, accuracy: 0.001)
    }

    func testBrushColorFallsBackToSystemYellowWhenUnset() {
        UserDefaults.standard.removeObject(forKey: "brushColorComponents")
        XCTAssertEqual(AppSettings.shared.brushColor, .systemYellow)
    }

    func testBrushLineWidthRoundTrips() {
        AppSettings.shared.brushLineWidth = 17
        XCTAssertEqual(AppSettings.shared.brushLineWidth, 17)
    }

    func testBrushLineWidthDefaultsToFourWhenUnset() {
        UserDefaults.standard.removeObject(forKey: "brushLineWidth")
        XCTAssertEqual(AppSettings.shared.brushLineWidth, 4)
    }

    // MARK: - Shortcut bindings

    func testBindingForActionReturnsDefaultWhenNoOverrideSet() {
        XCTAssertEqual(AppSettings.shared.binding(for: .toolHighlighter), ShortcutBinding.defaults[.toolHighlighter])
    }

    func testSetBindingOverridesTheDefault() {
        let custom = ShortcutBinding(keyCode: 40, modifiers: [.command, .option])
        AppSettings.shared.setBinding(custom, for: .toolHighlighter)
        XCTAssertEqual(AppSettings.shared.binding(for: .toolHighlighter), custom)
    }

    func testResetBindingRevertsToDefault() {
        let custom = ShortcutBinding(keyCode: 40, modifiers: [.command, .option])
        AppSettings.shared.setBinding(custom, for: .toolShape)
        AppSettings.shared.resetBinding(for: .toolShape)
        XCTAssertEqual(AppSettings.shared.binding(for: .toolShape), ShortcutBinding.defaults[.toolShape])
    }

    func testSetBindingPersistsAcrossOverridesReload() throws {
        // `setBinding` both updates the in-memory cache and writes JSON to
        // UserDefaults; decode that JSON directly to make sure the write side
        // actually happened rather than only the in-memory side.
        let custom = ShortcutBinding(keyCode: 40, modifiers: [.command, .option])
        AppSettings.shared.setBinding(custom, for: .toolHighlighter)

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "shortcutBindingsOverride"))
        let decoded = try JSONDecoder().decode([String: ShortcutBinding].self, from: data)
        XCTAssertEqual(decoded[ShortcutAction.toolHighlighter.rawValue], custom)
    }

    func testSetBindingPostsShortcutsChangedNotification() {
        let expectation = expectation(forNotification: .tapinkShortcutsChanged, object: nil)
        AppSettings.shared.setBinding(ShortcutBinding(keyCode: 40, modifiers: []), for: .toolHighlighter)
        wait(for: [expectation], timeout: 1)
    }

    func testResetBindingPostsShortcutsChangedNotification() {
        let expectation = expectation(forNotification: .tapinkShortcutsChanged, object: nil)
        AppSettings.shared.resetBinding(for: .toolHighlighter)
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - Region screenshot destination

    func testRegionScreenshotDestinationDefaultsToClipboard() {
        UserDefaults.standard.removeObject(forKey: regionDestinationKey)
        XCTAssertEqual(AppSettings.shared.regionScreenshotDestination, .clipboard)
    }

    func testRegionScreenshotDestinationRoundTrips() {
        AppSettings.shared.regionScreenshotDestination = .file
        XCTAssertEqual(AppSettings.shared.regionScreenshotDestination, .file)
        AppSettings.shared.regionScreenshotDestination = .clipboard
        XCTAssertEqual(AppSettings.shared.regionScreenshotDestination, .clipboard)
    }

    func testRegionScreenshotDestinationFallsBackToClipboardForUnknownStoredValue() {
        UserDefaults.standard.set("not-a-real-destination", forKey: regionDestinationKey)
        XCTAssertEqual(AppSettings.shared.regionScreenshotDestination, .clipboard)
    }

    // MARK: - Screenshot save folder

    func testScreenshotSaveFolderPathDefaultsToPicturesTapInk() {
        UserDefaults.standard.removeObject(forKey: screenshotFolderKey)
        XCTAssertEqual(AppSettings.shared.screenshotSaveFolderPath, AppSettings.defaultScreenshotFolder)
        XCTAssertTrue(AppSettings.defaultScreenshotFolder.hasSuffix("Pictures/TapInk"))
    }

    func testScreenshotSaveFolderPathRoundTrips() {
        AppSettings.shared.screenshotSaveFolderPath = "/tmp/TapInkTestFolder"
        XCTAssertEqual(AppSettings.shared.screenshotSaveFolderPath, "/tmp/TapInkTestFolder")
    }

    // MARK: - Max recording duration

    func testMaxRecordingDurationDefaultsToThirtyMinutesWhenUnset() {
        UserDefaults.standard.removeObject(forKey: maxRecordingDurationKey)
        XCTAssertEqual(AppSettings.shared.maxRecordingDurationMinutes, 30)
    }

    func testMaxRecordingDurationRoundTrips() {
        AppSettings.shared.maxRecordingDurationMinutes = 45
        XCTAssertEqual(AppSettings.shared.maxRecordingDurationMinutes, 45)
    }

    // MARK: - Hide from Dock / switcher

    func testHideFromDockAndSwitcherDefaultsToTrue() {
        UserDefaults.standard.removeObject(forKey: hideFromDockKey)
        XCTAssertTrue(AppSettings.shared.hideFromDockAndSwitcher)
    }

    func testSettingHideFromDockAndSwitcherInvokesCallbackWithNewValue() {
        var received: Bool?
        AppSettings.shared.onHideFromDockChanged = { received = $0 }
        AppSettings.shared.hideFromDockAndSwitcher = false
        XCTAssertEqual(received, false)
        XCTAssertFalse(AppSettings.shared.hideFromDockAndSwitcher)
    }
}
