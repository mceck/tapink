import XCTest
@testable import DrawzeeKit

final class ScreenshotServiceTests: XCTestCase {
    /// A region touching the bottom of the screen in AppKit's bottom-left-origin
    /// coordinates must map to the *bottom* rows of the pixel image (top-left origin).
    func testRegionAtBottomOfScreenMapsToBottomOfImage() {
        let region = CGRect(x: 0, y: 0, width: 100, height: 50)
        let pixelRect = ScreenshotService.pixelRect(forRegionInPoints: region, imageHeightInPixels: 1000, scale: 1)
        XCTAssertEqual(pixelRect, CGRect(x: 0, y: 950, width: 100, height: 50))
    }

    /// A region touching the top of the screen in AppKit coordinates (y close to the
    /// screen's point-height) must map to the *top* rows of the pixel image (y = 0).
    func testRegionAtTopOfScreenMapsToTopOfImage() {
        let region = CGRect(x: 0, y: 950, width: 100, height: 50)
        let pixelRect = ScreenshotService.pixelRect(forRegionInPoints: region, imageHeightInPixels: 1000, scale: 1)
        XCTAssertEqual(pixelRect, CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func testScalesForRetinaBackingScaleFactor() {
        let region = CGRect(x: 10, y: 20, width: 100, height: 50)
        // imageHeightInPixels: 2000px at scale 2 -> 1000pt-tall screen.
        let pixelRect = ScreenshotService.pixelRect(forRegionInPoints: region, imageHeightInPixels: 2000, scale: 2)
        XCTAssertEqual(pixelRect, CGRect(x: 20, y: 1860, width: 200, height: 100))
    }

    func testFullScreenRegionMapsToEntireImage() {
        let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let pixelRect = ScreenshotService.pixelRect(forRegionInPoints: region, imageHeightInPixels: 1000, scale: 1)
        XCTAssertEqual(pixelRect, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    func testResultIsAlwaysIntegralForFractionalInput() {
        let region = CGRect(x: 10.3, y: 20.7, width: 99.6, height: 49.2)
        let pixelRect = ScreenshotService.pixelRect(forRegionInPoints: region, imageHeightInPixels: 1000, scale: 1)
        XCTAssertEqual(pixelRect, pixelRect.integral, "cropping(to:) requires integral pixel bounds")
        XCTAssertEqual(pixelRect.origin.x.truncatingRemainder(dividingBy: 1), 0)
        XCTAssertEqual(pixelRect.origin.y.truncatingRemainder(dividingBy: 1), 0)
    }
}
