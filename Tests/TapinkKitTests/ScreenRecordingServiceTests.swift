import XCTest
@testable import TapInkKit

final class ScreenRecordingServiceTests: XCTestCase {
    /// A region touching the bottom of the screen in AppKit's bottom-left-origin coordinates
    /// must map to the *bottom* of the top-left-origin `sourceRect` (large y).
    func testRegionAtBottomOfScreenMapsToBottomOfSourceRect() {
        let region = CGRect(x: 0, y: 0, width: 100, height: 50)
        let sourceRect = ScreenRecordingService.sourceRect(forRegionInPoints: region, screenHeightInPoints: 1000)
        XCTAssertEqual(sourceRect, CGRect(x: 0, y: 950, width: 100, height: 50))
    }

    /// A region touching the top of the screen in AppKit coordinates (y close to the screen's
    /// point-height) must map to the *top* of the source rect (y = 0).
    func testRegionAtTopOfScreenMapsToTopOfSourceRect() {
        let region = CGRect(x: 0, y: 950, width: 100, height: 50)
        let sourceRect = ScreenRecordingService.sourceRect(forRegionInPoints: region, screenHeightInPoints: 1000)
        XCTAssertEqual(sourceRect, CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    /// Unlike `ScreenshotService.pixelRect`, `sourceRect` stays in points — no scale factor
    /// multiplies the dimensions here.
    func testStaysInPointsNotPixels() {
        let region = CGRect(x: 10, y: 20, width: 100, height: 50)
        let sourceRect = ScreenRecordingService.sourceRect(forRegionInPoints: region, screenHeightInPoints: 1000)
        XCTAssertEqual(sourceRect, CGRect(x: 10, y: 930, width: 100, height: 50))
    }

    func testFullScreenRegionMapsToEntireSourceRect() {
        let region = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let sourceRect = ScreenRecordingService.sourceRect(forRegionInPoints: region, screenHeightInPoints: 1000)
        XCTAssertEqual(sourceRect, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    func testEvenPixelLengthRoundsOddDownToEven() {
        XCTAssertEqual(ScreenRecordingService.evenPixelLength(101), 100)
        XCTAssertEqual(ScreenRecordingService.evenPixelLength(100), 100)
        XCTAssertEqual(ScreenRecordingService.evenPixelLength(99.6), 100)
        XCTAssertEqual(ScreenRecordingService.evenPixelLength(99.4), 98)
    }
}
