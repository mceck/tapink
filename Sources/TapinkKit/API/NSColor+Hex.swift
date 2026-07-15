import AppKit

/// The external API's JSON bodies describe colors as hex strings — nothing else in TapInk needs
/// this conversion, since the rest of the app only ever works with discrete `NSColor` swatches.
extension NSColor {
    /// Parses `"#RRGGBB"` or `"#RRGGBBAA"` (leading `#` optional). `nil` for anything else.
    convenience init?(hex: String) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let intValue = UInt32(value, radix: 16) else { return nil }

        let hasAlpha = value.count == 8
        let r, g, b, a: UInt32
        if hasAlpha {
            r = (intValue >> 24) & 0xFF
            g = (intValue >> 16) & 0xFF
            b = (intValue >> 8) & 0xFF
            a = intValue & 0xFF
        } else {
            r = (intValue >> 16) & 0xFF
            g = (intValue >> 8) & 0xFF
            b = intValue & 0xFF
            a = 0xFF
        }
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    var hexString: String {
        let rgba = usingColorSpace(.sRGB) ?? self
        let r = Int((rgba.redComponent * 255).rounded())
        let g = Int((rgba.greenComponent * 255).rounded())
        let b = Int((rgba.blueComponent * 255).rounded())
        let a = Int((rgba.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
