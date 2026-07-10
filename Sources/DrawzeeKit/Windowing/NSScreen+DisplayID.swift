import AppKit

public extension NSScreen {
    var displayID: ScreenID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
