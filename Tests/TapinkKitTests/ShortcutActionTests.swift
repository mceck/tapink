import XCTest
@testable import TapInkKit

final class ShortcutActionTests: XCTestCase {
    func testOnlyActivateDrawModeIsGlobal() {
        for action in ShortcutAction.allCases {
            XCTAssertEqual(action.isGlobal, action == .activateDrawMode, "\(action) has unexpected isGlobal")
        }
    }

    func testEveryActionHasANonEmptyDisplayName() {
        for action in ShortcutAction.allCases {
            XCTAssertFalse(action.displayName.isEmpty, "\(action) has an empty displayName")
        }
    }

    func testDisplayNamesAreUnique() {
        let names = ShortcutAction.allCases.map(\.displayName)
        XCTAssertEqual(names.count, Set(names).count, "two actions share a displayName, which would confuse the shortcuts UI")
    }

    /// `rawValue` is what's actually persisted as the dictionary key for shortcut
    /// overrides in UserDefaults (see `AppSettings.overrides`). Renaming a case
    /// changes its rawValue and silently orphans anyone's saved customization for
    /// that action, reverting it to default with no migration or warning — this
    /// test exists to make that rename a deliberate, visible decision.
    func testRawValuesAreStable() {
        let expected: [ShortcutAction: String] = [
            .activateDrawMode: "activateDrawMode",
            .exitDrawMode: "exitDrawMode",
            .copyScreenshot: "copyScreenshot",
            .saveScreenshot: "saveScreenshot",
            .regionScreenshot: "regionScreenshot",
            .recordScreen: "recordScreen",
            .regionRecording: "regionRecording",
            .freezeBackground: "freezeBackground",
            .clearCanvas: "clearCanvas",
            .undo: "undo",
            .redo: "redo",
            .toolPen: "toolPen",
            .toolHighlighter: "toolHighlighter",
            .toolShape: "toolShape",
            .toolSpotlight: "toolSpotlight",
            .toolText: "toolText",
            .toolMove: "toolMove",
            .toolEraser: "toolEraser",
            .hideCanvas: "hideCanvas",
            .toggleAutofade: "toggleAutofade",
            .shapeRectangle: "shapeRectangle",
            .shapeEllipse: "shapeEllipse",
            .shapeLine: "shapeLine",
            .shapeArrow: "shapeArrow",
            .toggleSidebar: "toggleSidebar",
            .hideSidebar: "hideSidebar",
        ]
        XCTAssertEqual(expected.count, ShortcutAction.allCases.count, "a case was added or removed without updating this test")
        for (action, rawValue) in expected {
            XCTAssertEqual(action.rawValue, rawValue)
        }
    }
}
