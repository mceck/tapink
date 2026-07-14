import XCTest
import AppKit
@testable import TapInkKit

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
            // For `.cubicCurveTo`, `associatedPoints` is [controlPoint1, controlPoint2,
            // endpoint] — the destination is the third point, not the first.
            let point = type == .cubicCurveTo ? raw[2] : raw[0]
            return Element(type: type, point: point)
        }
    }

    private func assertPoint(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 0.001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testPathHasSixElementsShaftPlusTwoIndependentBarbs() {
        // Shaft (move+line) and each barb (move+line) are three independent
        // subpaths — not five elements with the shaft bleeding into the first
        // barb — so no join is ever computed at the tip; see the comment on
        // the `path.move(to: end)` calls in `arrowPath`.
        let path = CanvasView.arrowPath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        XCTAssertEqual(path.elementCount, 6)
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

        // Each barb is its own subpath, independently moved-to from the tip —
        // not a continuation of the shaft's last point — so both `moveTo`s
        // (index 2 for the first barb, index 4 for the second) land at `end`.
        XCTAssertEqual(elements[2].type, .moveTo)
        assertPoint(elements[2].point, end, accuracy: 0.5)
        XCTAssertEqual(elements[4].type, .moveTo)
        assertPoint(elements[4].point, end, accuracy: 0.5)
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
            let p1 = elements[3].point
            let p2 = elements[5].point

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
        XCTAssertEqual(elements.count, 6)
        for element in elements {
            XCTAssertTrue(element.point.x.isFinite, "arrow geometry produced a non-finite x for a zero-length shaft")
            XCTAssertTrue(element.point.y.isFinite, "arrow geometry produced a non-finite y for a zero-length shaft")
        }
    }

    // MARK: - isHit(at:) (move & eraser tools)

    func testStrokeHitsOnThePathAndMissesFarAway() {
        let stroke = DrawingObject.stroke(StrokeObject(
            screen: 1, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            color: .red, width: 4, isHighlighter: false
        ))
        XCTAssertTrue(stroke.isHit(at: CGPoint(x: 50, y: 0)))
        XCTAssertTrue(stroke.isHit(at: CGPoint(x: 50, y: 8)), "click within tolerance of a thin stroke should hit")
        XCTAssertFalse(stroke.isHit(at: CGPoint(x: 50, y: 40)))
    }

    func testHighlighterHitAreaTracksItsTripledDrawnWidth() {
        let highlighter = DrawingObject.stroke(StrokeObject(
            screen: 1, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            color: .red, width: 10, isHighlighter: true
        ))
        // Drawn width is 30 (10 * 3), so 15 + 8 tolerance from the centerline still hits.
        XCTAssertTrue(highlighter.isHit(at: CGPoint(x: 50, y: 20)))
        XCTAssertFalse(highlighter.isHit(at: CGPoint(x: 50, y: 30)))
    }

    func testRectangleHitsOnTheOutlineButNotInTheHollowInterior() {
        let rect = DrawingObject.shape(ShapeObject(
            screen: 1, kind: .rectangle, startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 100, y: 100), color: .red, width: 4
        ))
        XCTAssertTrue(rect.isHit(at: CGPoint(x: 50, y: 0)), "bottom edge should hit")
        XCTAssertTrue(rect.isHit(at: CGPoint(x: 100, y: 50)), "right edge should hit")
        XCTAssertFalse(
            rect.isHit(at: CGPoint(x: 50, y: 50)),
            "a hollow rectangle's center must not hit, or it would block grabbing objects drawn inside it"
        )
    }

    func testTextHitsInsideItsBoundingBoxAndMissesOutside() {
        let text = DrawingObject.text(TextObject(
            screen: 1, origin: CGPoint(x: 100, y: 100), string: "hello", color: .red, fontSize: 24
        ))
        // origin is the bottom-left of the glyph box in a non-flipped canvas.
        XCTAssertTrue(text.isHit(at: CGPoint(x: 110, y: 110)))
        XCTAssertFalse(text.isHit(at: CGPoint(x: 100, y: 200)))
        XCTAssertFalse(text.isHit(at: CGPoint(x: 50, y: 110)), "left of the box must miss")
    }

    // MARK: - constrainedShapePoint (Shift-to-square/circle)

    func testShiftNotHeldReturnsThePointUnchanged() {
        let point = CGPoint(x: 130, y: 40)
        let result = CanvasView.constrainedShapePoint(from: .zero, to: point, kind: .rectangle, shiftHeld: false)
        assertPoint(result, point)
    }

    func testShiftHeldOnLineOrArrowLeavesThePointUnchanged() {
        let point = CGPoint(x: 130, y: 40)
        for kind: ShapeKind in [.line, .arrow] {
            let result = CanvasView.constrainedShapePoint(from: .zero, to: point, kind: kind, shiftHeld: true)
            assertPoint(result, point)
        }
    }

    func testShiftHeldOnRectangleOrEllipseLocksToTheLargerDelta() {
        let start = CGPoint(x: 0, y: 0)
        for kind: ShapeKind in [.rectangle, .ellipse] {
            // Wider than tall: the shorter (y) delta is stretched to match x.
            assertPoint(
                CanvasView.constrainedShapePoint(from: start, to: CGPoint(x: 100, y: 40), kind: kind, shiftHeld: true),
                CGPoint(x: 100, y: 100)
            )
            // Taller than wide: the shorter (x) delta is stretched to match y.
            assertPoint(
                CanvasView.constrainedShapePoint(from: start, to: CGPoint(x: 40, y: 100), kind: kind, shiftHeld: true),
                CGPoint(x: 100, y: 100)
            )
        }
    }

    func testShiftHeldPreservesTheDragDirectionInBothAxes() {
        let start = CGPoint(x: 50, y: 50)
        let result = CanvasView.constrainedShapePoint(from: start, to: CGPoint(x: 10, y: 5), kind: .rectangle, shiftHeld: true)
        assertPoint(result, CGPoint(x: 5, y: 5))
    }

    // MARK: - smoothedPath (freehand stroke smoothing)

    func testSinglePointProducesNoDrawableSegment() {
        // Guarded upstream by `drawStroke`'s `points.count > 1` check, but the
        // helper itself shouldn't crash if ever called with a lone point.
        let path = CanvasView.smoothedPath(through: [CGPoint(x: 5, y: 5)])
        XCTAssertEqual(path.elementCount, 1)
        XCTAssertEqual(elements(of: path)[0].type, .moveTo)
    }

    func testTwoPointsProduceAStraightLine() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 40)
        let path = CanvasView.smoothedPath(through: [start, end])
        let els = elements(of: path)

        XCTAssertEqual(els.count, 2)
        XCTAssertEqual(els[0].type, .moveTo)
        assertPoint(els[0].point, start)
        XCTAssertEqual(els[1].type, .lineTo)
        assertPoint(els[1].point, end)
    }

    /// Three points produce: a (degenerate, but still a real curve element) straight
    /// lead-in from the first point to the first midpoint, a curve rounding the
    /// corner at the middle point, and a straight lead-out from the last midpoint
    /// to the final point.
    func testThreePointsRoundTheMiddleCornerWithStraightLeadInAndOut() {
        let p0 = CGPoint(x: 0, y: 0)
        let p1 = CGPoint(x: 50, y: 30)
        let p2 = CGPoint(x: 100, y: 0)
        let path = CanvasView.smoothedPath(through: [p0, p1, p2])
        let els = elements(of: path)

        XCTAssertEqual(els.count, 4)
        XCTAssertEqual(els[0].type, .moveTo)
        assertPoint(els[0].point, p0)

        let mid01 = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let mid12 = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        XCTAssertEqual(els[1].type, .cubicCurveTo)
        assertPoint(els[1].point, mid01)
        XCTAssertEqual(els[2].type, .cubicCurveTo)
        assertPoint(els[2].point, mid12)
        XCTAssertEqual(els[3].type, .lineTo)
        assertPoint(els[3].point, p2)
    }

    /// The lead-in curve's quad control point equals its own start point (`p0`),
    /// which makes it mathematically degenerate into a straight line even though
    /// it's still emitted as a `cubicCurveTo` element — verified here by checking
    /// its associated control points are colinear with the p0->mid01 segment
    /// rather than bulging off of it.
    func testLeadInCurveIsColinearDespiteBeingACurveElement() {
        let p0 = CGPoint(x: 0, y: 0)
        let p1 = CGPoint(x: 50, y: 30)
        let p2 = CGPoint(x: 100, y: 0)
        let path = CanvasView.smoothedPath(through: [p0, p1, p2])

        var raw = [NSPoint](repeating: .zero, count: 3)
        let type = raw.withUnsafeMutableBufferPointer { buffer in
            path.element(at: 1, associatedPoints: buffer.baseAddress)
        }
        XCTAssertEqual(type, .cubicCurveTo)

        let mid01 = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        for controlPoint in [raw[0], raw[1]] {
            let cross = (controlPoint.x - p0.x) * (mid01.y - p0.y) - (controlPoint.y - p0.y) * (mid01.x - p0.x)
            XCTAssertEqual(cross, 0, accuracy: 0.001, "lead-in control point strayed off the p0->mid01 line")
        }
    }

    func testProducedPathStaysWithinTheBoundingBoxOfItsInputPoints() {
        // A smoothed stroke should never overshoot its own samples — every element's
        // associated point (including cubic control points) must stay within the
        // bounding box of the raw input, otherwise the curve would visibly bulge
        // past where the pointer actually moved.
        let points = [
            CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 40), CGPoint(x: 60, y: -10),
            CGPoint(x: 90, y: 30), CGPoint(x: 120, y: 0),
        ]
        let path = CanvasView.smoothedPath(through: points)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!

        var raw = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            let type = raw.withUnsafeMutableBufferPointer { buffer in
                path.element(at: index, associatedPoints: buffer.baseAddress)
            }
            let count = type == .cubicCurveTo ? 3 : 1
            for i in 0..<count {
                XCTAssertGreaterThanOrEqual(raw[i].x, minX - 0.001)
                XCTAssertLessThanOrEqual(raw[i].x, maxX + 0.001)
                XCTAssertGreaterThanOrEqual(raw[i].y, minY - 0.001)
                XCTAssertLessThanOrEqual(raw[i].y, maxY + 0.001)
            }
        }
    }
}
