import XCTest
import AppKit
@testable import TapInkKit

final class NSColorHexTests: XCTestCase {
    func testParsesRGB() {
        let color = NSColor(hex: "#FF0000")
        let rgba = color?.usingColorSpace(.sRGB)
        XCTAssertEqual(rgba?.redComponent ?? -1, 1, accuracy: 0.01)
        XCTAssertEqual(rgba?.greenComponent ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(rgba?.blueComponent ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(rgba?.alphaComponent ?? -1, 1, accuracy: 0.01)
    }

    func testParsesRGBAWithoutHash() {
        let color = NSColor(hex: "0000FF80")
        let rgba = color?.usingColorSpace(.sRGB)
        XCTAssertEqual(rgba?.blueComponent ?? -1, 1, accuracy: 0.01)
        XCTAssertEqual(rgba?.alphaComponent ?? -1, 128.0 / 255.0, accuracy: 0.01)
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(NSColor(hex: "not-a-color"))
        XCTAssertNil(NSColor(hex: "#FFF"))
    }

    func testHexStringRoundTrip() {
        let original = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let reparsed = NSColor(hex: original.hexString)
        let a = original.usingColorSpace(.sRGB)
        let b = reparsed?.usingColorSpace(.sRGB)
        XCTAssertEqual(a?.redComponent ?? -1, b?.redComponent ?? -2, accuracy: 0.01)
        XCTAssertEqual(a?.greenComponent ?? -1, b?.greenComponent ?? -2, accuracy: 0.01)
        XCTAssertEqual(a?.blueComponent ?? -1, b?.blueComponent ?? -2, accuracy: 0.01)
    }
}
