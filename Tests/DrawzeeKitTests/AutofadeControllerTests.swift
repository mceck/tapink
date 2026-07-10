import XCTest
@testable import DrawzeeKit

/// Covers the erase-duration policy: strokes unwind at a constant along-the-path
/// speed (so duration scales with length), clamped at both ends, while shapes
/// and text get the fixed alpha-fade duration. The timer-driven lifecycle
/// itself is exercised interactively, not here — these are the pure decisions
/// underneath it.
final class AutofadeControllerTests: XCTestCase {
    private func stroke(length: CGFloat) -> DrawingObject {
        .stroke(StrokeObject(
            screen: 1, points: [.zero, CGPoint(x: length, y: 0)],
            color: .red, width: 2, isHighlighter: false
        ))
    }

    func testShortStrokeIsClampedToTheMinimumDuration() {
        XCTAssertEqual(AutofadeController.eraseDuration(for: stroke(length: 10)), 0.3, accuracy: 0.001)
    }

    func testVeryLongStrokeIsClampedToTheMaximumDuration() {
        XCTAssertEqual(AutofadeController.eraseDuration(for: stroke(length: 100_000)), 1.2, accuracy: 0.001)
    }

    func testMidLengthStrokeDurationScalesWithArcLength() {
        // 1800pt at the 3000pt/s retract speed = 0.6s, inside both clamps.
        XCTAssertEqual(AutofadeController.eraseDuration(for: stroke(length: 1800)), 0.6, accuracy: 0.001)
    }

    func testShapesAndTextUseTheFixedAlphaFadeDuration() {
        let shape = DrawingObject.shape(ShapeObject(
            screen: 1, kind: .rectangle, startPoint: .zero,
            endPoint: CGPoint(x: 100, y: 100), color: .red, width: 2
        ))
        let text = DrawingObject.text(TextObject(
            screen: 1, origin: .zero, string: "hi", color: .red, fontSize: 24
        ))
        XCTAssertEqual(AutofadeController.eraseDuration(for: shape), 0.35, accuracy: 0.001)
        XCTAssertEqual(AutofadeController.eraseDuration(for: text), 0.35, accuracy: 0.001)
    }
}
