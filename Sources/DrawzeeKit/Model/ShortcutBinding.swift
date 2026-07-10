import AppKit
import Carbon.HIToolbox

public struct ShortcutBinding: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: UInt

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    public func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifierFlags
    }

    public var displayString: String {
        var result = ""
        let flags = modifierFlags
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += ShortcutBinding.keyCodeToString(keyCode)
        return result
    }

    private static let keyCodeNames: [UInt16: String] = [
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Escape): "Esc",
        UInt16(kVK_Delete): "Delete",
        UInt16(kVK_ForwardDelete): "Fwd Delete",
        UInt16(kVK_Return): "Return",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
    ]

    static func keyCodeToString(_ keyCode: UInt16) -> String {
        keyCodeNames[keyCode] ?? "Key \(keyCode)"
    }
}

extension ShortcutBinding {
    public static let defaults: [ShortcutAction: ShortcutBinding] = [
        .activateDrawMode: ShortcutBinding(keyCode: UInt16(kVK_Tab), modifiers: [.option]),
        .exitDrawMode: ShortcutBinding(keyCode: UInt16(kVK_Escape), modifiers: []),
        .copyScreenshot: ShortcutBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command]),
        .saveScreenshot: ShortcutBinding(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command]),
        .regionScreenshot: ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .shift]),
        .freezeBackground: ShortcutBinding(keyCode: UInt16(kVK_ANSI_L), modifiers: []),
        .clearCanvas: ShortcutBinding(keyCode: UInt16(kVK_Delete), modifiers: []),
        .undo: ShortcutBinding(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command]),
        .redo: ShortcutBinding(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command, .shift]),
        .toolPen: ShortcutBinding(keyCode: UInt16(kVK_ANSI_P), modifiers: []),
        .toolHighlighter: ShortcutBinding(keyCode: UInt16(kVK_ANSI_H), modifiers: []),
        .toolShape: ShortcutBinding(keyCode: UInt16(kVK_ANSI_S), modifiers: []),
        .toolSpotlight: ShortcutBinding(keyCode: UInt16(kVK_ANSI_F), modifiers: []),
        .toolText: ShortcutBinding(keyCode: UInt16(kVK_ANSI_T), modifiers: []),
        .toolMove: ShortcutBinding(keyCode: UInt16(kVK_ANSI_V), modifiers: []),
        .toolEraser: ShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: []),
        .hideCanvas: ShortcutBinding(keyCode: UInt16(kVK_ANSI_E), modifiers: []),
        .toggleAutofade: ShortcutBinding(keyCode: UInt16(kVK_Space), modifiers: []),
        .shapeRectangle: ShortcutBinding(keyCode: UInt16(kVK_ANSI_1), modifiers: []),
        .shapeEllipse: ShortcutBinding(keyCode: UInt16(kVK_ANSI_2), modifiers: []),
        .shapeLine: ShortcutBinding(keyCode: UInt16(kVK_ANSI_3), modifiers: []),
        .shapeArrow: ShortcutBinding(keyCode: UInt16(kVK_ANSI_4), modifiers: []),
        .toggleSidebar: ShortcutBinding(keyCode: UInt16(kVK_ANSI_W), modifiers: [.option]),
        .hideSidebar: ShortcutBinding(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command]),
    ]
}
