import XCTest
import AppKit
@testable import DrawzeeKit

final class ToolTests: XCTestCase {
    // MARK: - ShapeKind

    func testShapeKindHasNonEmptyDisplayNameAndSymbolForEveryCase() {
        for kind in ShapeKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind) has an empty displayName")
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) has an empty symbolName")
        }
    }

    func testShapeKindDisplayNamesAreUnique() {
        let names = ShapeKind.allCases.map(\.displayName)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testShapeKindCodableRoundTrips() throws {
        for kind in ShapeKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(ShapeKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    /// `rawValue` is persisted implicitly wherever a `ShapeKind` round-trips through
    /// `Codable` storage; locking these down makes a silent rename a visible test failure.
    func testShapeKindRawValuesAreStable() {
        XCTAssertEqual(ShapeKind.rectangle.rawValue, "rectangle")
        XCTAssertEqual(ShapeKind.ellipse.rawValue, "ellipse")
        XCTAssertEqual(ShapeKind.line.rawValue, "line")
        XCTAssertEqual(ShapeKind.arrow.rawValue, "arrow")
    }

    // MARK: - DrawingTool

    func testDrawingToolCodableRoundTrips() throws {
        for tool in DrawingTool.allCases {
            let data = try JSONEncoder().encode(tool)
            let decoded = try JSONDecoder().decode(DrawingTool.self, from: data)
            XCTAssertEqual(decoded, tool)
        }
    }

    func testDrawingToolRawValuesAreStable() {
        XCTAssertEqual(DrawingTool.pen.rawValue, "pen")
        XCTAssertEqual(DrawingTool.highlighter.rawValue, "highlighter")
        XCTAssertEqual(DrawingTool.shape.rawValue, "shape")
        XCTAssertEqual(DrawingTool.spotlight.rawValue, "spotlight")
        XCTAssertEqual(DrawingTool.text.rawValue, "text")
    }

    // MARK: - ToolState

    func testToolStateDefaults() {
        let state = ToolState()
        XCTAssertEqual(state.selectedTool, .pen)
        XCTAssertEqual(state.selectedShape, .rectangle)
        XCTAssertEqual(state.color, .systemYellow)
        XCTAssertEqual(state.lineWidth, 4)
    }

    func testToolStateFieldsAreIndependentlyMutable() {
        var state = ToolState()
        state.selectedTool = .shape
        state.selectedShape = .arrow
        state.color = .systemRed
        state.lineWidth = 10

        XCTAssertEqual(state.selectedTool, .shape)
        XCTAssertEqual(state.selectedShape, .arrow)
        XCTAssertEqual(state.color, .systemRed)
        XCTAssertEqual(state.lineWidth, 10)
    }
}
