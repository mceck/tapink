import XCTest
import AppKit
import Carbon.HIToolbox
@testable import DrawzeeKit

final class ShortcutBindingTests: XCTestCase {
    func testEncodeDecodeRoundTrips() throws {
        let binding = ShortcutBinding(keyCode: 6, modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
        XCTAssertEqual(binding, decoded)
    }

    func testMatchesRequiresSameKeyCodeAndModifiers() {
        let binding = ShortcutBinding(keyCode: 8, modifiers: [.command])
        let matchingEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        )!
        XCTAssertTrue(binding.matches(matchingEvent))

        let wrongKeyEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        )!
        XCTAssertFalse(binding.matches(wrongKeyEvent))
    }

    func testDefaultsCoverEveryAction() {
        for action in ShortcutAction.allCases {
            XCTAssertNotNil(ShortcutBinding.defaults[action], "missing default binding for \(action)")
        }
    }

    func testUndoAndRedoDefaultsAreDistinct() {
        XCTAssertNotEqual(ShortcutBinding.defaults[.undo], ShortcutBinding.defaults[.redo])
    }

    func testInitStripsDeviceDependentModifierBits() {
        // Any raw bit outside `.deviceIndependentFlagsMask` (real NSEvents commonly carry
        // some) must not leak into stored `modifiers`, or two otherwise-identical bindings
        // built from slightly different raw events would compare unequal.
        let dirtyFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x1)
        let binding = ShortcutBinding(keyCode: 8, modifiers: dirtyFlags)
        XCTAssertEqual(binding.modifiers, NSEvent.ModifierFlags.command.rawValue)
    }

    func testMatchesIgnoresDeviceDependentModifierBitsOnTheEvent() {
        let binding = ShortcutBinding(keyCode: 8, modifiers: [.command])
        let eventWithExtraBits = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x100),
            timestamp: 0, windowNumber: 0, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        )!
        XCTAssertTrue(binding.matches(eventWithExtraBits))
    }

    func testMatchesFailsWhenModifiersDiffer() {
        let binding = ShortcutBinding(keyCode: 8, modifiers: [.command])
        let shiftEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        )!
        XCTAssertFalse(binding.matches(shiftEvent))
    }

    func testDisplayStringOrdersModifiersControlOptionShiftCommand() {
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(binding.displayString, "⌃⌥⇧⌘A")
    }

    func testDisplayStringWithNoModifiers() {
        let binding = ShortcutBinding(keyCode: UInt16(kVK_Escape), modifiers: [])
        XCTAssertEqual(binding.displayString, "Esc")
    }

    func testDisplayStringFallsBackToRawKeyCodeForUnnamedKeys() {
        let binding = ShortcutBinding(keyCode: 200, modifiers: [])
        XCTAssertEqual(binding.displayString, "Key 200")
    }

    func testDisplayStringForEachDefaultIsNonEmpty() {
        for (action, binding) in ShortcutBinding.defaults {
            XCTAssertFalse(binding.displayString.isEmpty, "empty displayString for \(action)")
        }
    }

    func testCodableRoundTripsThroughActionKeyedDictionary() throws {
        // Mirrors exactly how AppSettings persists overrides (`[String: ShortcutBinding]`
        // keyed by `ShortcutAction.rawValue`) — a regression here would corrupt saved
        // shortcut customizations on every user's machine.
        var overrides: [String: ShortcutBinding] = [:]
        for (action, binding) in ShortcutBinding.defaults {
            overrides[action.rawValue] = binding
        }
        let data = try JSONEncoder().encode(overrides)
        let decoded = try JSONDecoder().decode([String: ShortcutBinding].self, from: data)
        XCTAssertEqual(decoded, overrides)
    }
}
