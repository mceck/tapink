import XCTest
import AppKit
@testable import DrawzeeKit

/// Covers `CanvasView.arrowPath`'s trigonometry directly. The arrow tool is drawn as a
/// shaft plus two backward-swept barbs computed with `atan2`/`cos`/`sin` — exactly the
/// kind of math where a sign slip silently points the arrowhead the wrong way, which
/// wouldn't be caught by anything else in this suite since normal rendering is never
/// asserted on.
final class CanvasViewGeometryTests: XCTestCase {
    // Must track the private constants inside `CanvasView.arrowPath`; update both if
    // that implementation's arrow length/spread angle intentionally changes.
    private let arrowLength: CGFloat = 18
    private let arrowAngle: CGFloat = .pi / 7

    private struct Element {
        let type: NSBezierPath.ElementType
        let point: CGPoint
    }

    private func elements(of path: NSBezierPath) -> [Element] {
        var raw = [NSPoint](repeating: .zero, count: 3)
        return (0..<path.elementCount).map { index in
            let type = raw.withUnsafeMutableBufferPointer { buffer in
                path.element(at: index, associatedPoints: buffer.baseAddress)
            }
            return Element(type: type, point: raw[0])
        }
    }

    private func assertPoint(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 0.001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testPathHasFiveElementsShaftPlusTwoBarbs() {
        let path = CanvasView.arrowPath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        XCTAssertEqual(path.elementCount, 5)
    }

    func testShaftGoesDirectlyFromStartToEnd() {
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 130, y: 87)
        let elements = elements(of: CanvasView.arrowPath(from: start, to: end))

        XCTAssertEqual(elements[0].type, .moveTo)
        assertPoint(elements[0].point, start)
        XCTAssertEqual(elements[1].type, .lineTo)
        assertPoint(elements[1].point, end)
    }

    func testBothBarbsStartFromTheArrowTip() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 40)
        let elements = elements(of: CanvasView.arrowPath(from: start, to: end))

        XCTAssertEqual(elements[3].type, .moveTo)
        assertPoint(elements[3].point, end, accuracy: 0.5)
    }

    /// For a variety of shaft directions, both barbs must be exactly `arrowLength` from
    /// the tip and swept `arrowAngle` off the reversed shaft direction — one to either side.
    func testBarbsAreSymmetricAtTheConfiguredLengthAndAngle() {
        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)),     // pointing right
            (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)),     // pointing up
            (CGPoint(x: 0, y: 0), CGPoint(x: -100, y: 0)),    // pointing left
            (CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)),   // 45 degrees
            (CGPoint(x: 50, y: 50), CGPoint(x: 10, y: 5)),    // arbitrary, reversed-ish
        ]

        for (start, end) in cases {
            let elements = elements(of: CanvasView.arrowPath(from: start, to: end))
            let p1 = elements[2].point
            let p2 = elements[4].point

            let shaftAngle = atan2(end.y - start.y, end.x - start.x)
            let backAlongShaft = shaftAngle + .pi

            for (barb, expectedOffset) in [(p1, -arrowAngle), (p2, arrowAngle)] {
                let vector = CGPoint(x: barb.x - end.x, y: barb.y - end.y)
                let length = hypot(vector.x, vector.y)
                XCTAssertEqual(length, arrowLength, accuracy: 0.01, "barb length drifted from the configured arrow length")

                let barbAngle = atan2(vector.y, vector.x)
                var delta = barbAngle - (backAlongShaft + expectedOffset)
                // Normalize to (-pi, pi] before comparing, since angles wrap.
                while delta > .pi { delta -= 2 * .pi }
                while delta <= -.pi { delta += 2 * .pi }
                XCTAssertEqual(delta, 0, accuracy: 0.01, "barb swept at the wrong angle off the shaft")
            }
        }
    }

    func testDegenerateZeroLengthArrowProducesFiniteGeometry() {
        let point = CGPoint(x: 42, y: 42)
        let elements = elements(of: CanvasView.arrowPath(from: point, to: point))
        XCTAssertEqual(elements.count, 5)
        for element in elements {
            XCTAssertTrue(element.point.x.isFinite, "arrow geometry produced a non-finite x for a zero-length shaft")
            XCTAssertTrue(element.point.y.isFinite, "arrow geometry produced a non-finite y for a zero-length shaft")
        }
    }
}
