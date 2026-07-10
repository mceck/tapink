import XCTest
@testable import DrawzeeKit

/// Covers the arc-length truncation behind the auto-fade retract animation.
/// Truncation is measured along the path (not by point count) and interpolates
/// the cut point — both are what make the erasing tip move at a steady speed,
/// and neither would be caught visually except as subtle stutter.
final class StrokeGeometryTests: XCTestCase {
    private func assertPoint(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 0.001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - length

    func testLengthOfEmptyAndSinglePointIsZero() {
        XCTAssertEqual(StrokeGeometry.length(of: []), 0)
        XCTAssertEqual(StrokeGeometry.length(of: [CGPoint(x: 5, y: 5)]), 0)
    }

    func testLengthSumsSegments() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4), CGPoint(x: 3, y: 14)]
        XCTAssertEqual(StrokeGeometry.length(of: points), 15, accuracy: 0.001)
    }

    // MARK: - truncated

    func testFractionOneReturnsAllPointsUnchanged() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        XCTAssertEqual(StrokeGeometry.truncated(points, keepingFraction: 1), points)
    }

    func testFractionZeroOrNegativeReturnsNothing() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        XCTAssertTrue(StrokeGeometry.truncated(points, keepingFraction: 0).isEmpty)
        XCTAssertTrue(StrokeGeometry.truncated(points, keepingFraction: -0.5).isEmpty)
    }

    func testHalfFractionCutsAtHalfTheArcLengthNotHalfThePoints() {
        // Uneven sampling: three points but 90% of the length is in the first
        // segment. Cutting by point count would keep two segments; cutting by
        // arc length must land inside the first one.
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0), CGPoint(x: 100, y: 0)]
        let result = StrokeGeometry.truncated(points, keepingFraction: 0.5)
        XCTAssertEqual(result.count, 2)
        assertPoint(result[0], points[0])
        assertPoint(result[1], CGPoint(x: 50, y: 0))
    }

    func testCutPointIsInterpolatedAlongTheSegmentWhereItLands() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        // Total length 20; keeping 0.75 -> 15 -> 5 into the vertical segment.
        let result = StrokeGeometry.truncated(points, keepingFraction: 0.75)
        XCTAssertEqual(result.count, 3)
        assertPoint(result.last!, CGPoint(x: 10, y: 5))
    }

    func testTruncationNeverStraysFromTheOriginalPath() {
        let points = [
            CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 40), CGPoint(x: 60, y: -10),
            CGPoint(x: 90, y: 30), CGPoint(x: 120, y: 0),
        ]
        for fraction in stride(from: CGFloat(0.1), through: 0.9, by: 0.1) {
            let result = StrokeGeometry.truncated(points, keepingFraction: fraction)
            XCTAssertGreaterThanOrEqual(result.count, 2, "a non-degenerate cut should keep a drawable stroke")
            // Every kept point except the interpolated tip must be an original sample, in order.
            XCTAssertEqual(Array(result.dropLast()), Array(points.prefix(result.count - 1)))
            let keptLength = StrokeGeometry.length(of: result)
            let expected = StrokeGeometry.length(of: points) * fraction
            XCTAssertEqual(keptLength, expected, accuracy: 0.01, "kept arc length drifted from the requested fraction")
        }
    }

    func testZeroLengthStrokeTruncatesToNothingWithoutCrashing() {
        let point = CGPoint(x: 42, y: 42)
        XCTAssertTrue(StrokeGeometry.truncated([point, point], keepingFraction: 0.5).isEmpty)
    }

    // MARK: - trailing (what the erase animation actually renders)

    func testTrailingKeepsTheEndOfTheStrokeNotTheStart() {
        // The eraser retraces the stroke from its first point, so what
        // survives mid-animation must be a suffix of the path: the last
        // point stays put while the leading tip has moved forward.
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        // Total length 20; keeping 0.25 -> the last 5 of the vertical segment.
        let result = StrokeGeometry.trailing(points, keepingFraction: 0.25)
        XCTAssertEqual(result.count, 2)
        assertPoint(result[0], CGPoint(x: 10, y: 5))
        assertPoint(result[1], CGPoint(x: 10, y: 10))
    }

    func testTrailingFractionOneReturnsAllPointsInOriginalOrder() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        XCTAssertEqual(StrokeGeometry.trailing(points, keepingFraction: 1), points)
    }

    func testTrailingFractionZeroReturnsNothing() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        XCTAssertTrue(StrokeGeometry.trailing(points, keepingFraction: 0).isEmpty)
    }

    func testTrailingIsTheMirrorOfTruncated() {
        let points = [
            CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 40), CGPoint(x: 60, y: -10),
            CGPoint(x: 90, y: 30), CGPoint(x: 120, y: 0),
        ]
        for fraction in stride(from: CGFloat(0.1), through: 0.9, by: 0.1) {
            let trailing = StrokeGeometry.trailing(points, keepingFraction: fraction)
            let mirrored = StrokeGeometry.truncated(points.reversed(), keepingFraction: fraction).reversed()
            XCTAssertEqual(trailing, Array(mirrored))
            let keptLength = StrokeGeometry.length(of: trailing)
            let expected = StrokeGeometry.length(of: points) * fraction
            XCTAssertEqual(keptLength, expected, accuracy: 0.01)
        }
    }
}
