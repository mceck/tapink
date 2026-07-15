import XCTest
@testable import TapInkKit

final class APICoordinatesTests: XCTestCase {
    /// Top-left pixel origin (0,0) at 1x scale should map to AppKit's top edge, i.e. y equal to
    /// the screen height (AppKit's bottom-left origin puts y = height at the top).
    func testTopLeftCorner() {
        let point = APICoordinates.point(fromPixel: CGPoint(x: 0, y: 0), screenHeightInPoints: 900, scale: 1)
        XCTAssertEqual(point, CGPoint(x: 0, y: 900))
    }

    /// Bottom-left pixel (0, height) should map to AppKit's origin (0, 0).
    func testBottomLeftCorner() {
        let point = APICoordinates.point(fromPixel: CGPoint(x: 0, y: 900), screenHeightInPoints: 900, scale: 1)
        XCTAssertEqual(point, CGPoint(x: 0, y: 0))
    }

    /// A Retina (2x) display's pixel coordinates must be divided by scale before flipping.
    func testScaledDisplay() {
        let point = APICoordinates.point(fromPixel: CGPoint(x: 200, y: 100), screenHeightInPoints: 900, scale: 2)
        XCTAssertEqual(point, CGPoint(x: 100, y: 850))
    }
}
