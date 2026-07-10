import XCTest
@testable import DrawzeeKit

final class DrawingDocumentTests: XCTestCase {
    private func sampleStroke(screen: ScreenID = 1) -> DrawingObject {
        .stroke(StrokeObject(screen: screen, points: [.zero, CGPoint(x: 1, y: 1)], color: .red, width: 2, isHighlighter: false))
    }

    func testAddAppendsObject() {
        let document = DrawingDocument()
        document.add(sampleStroke())
        XCTAssertEqual(document.objects.count, 1)
    }

    func testUndoRemovesLastObject() {
        let document = DrawingDocument()
        document.add(sampleStroke())
        document.undo()
        XCTAssertTrue(document.objects.isEmpty)
    }

    func testRedoRestoresUndoneObject() {
        let document = DrawingDocument()
        document.add(sampleStroke())
        document.undo()
        document.redo()
        XCTAssertEqual(document.objects.count, 1)
    }

    func testNewActionClearsRedoStack() {
        let document = DrawingDocument()
        document.add(sampleStroke())
        document.undo()
        document.add(sampleStroke())
        document.redo()
        XCTAssertEqual(document.objects.count, 1, "redo should be a no-op once a new action has been recorded")
    }

    func testClearRemovesEverything() {
        let document = DrawingDocument()
        document.add(sampleStroke())
        document.add(sampleStroke())
        document.clear()
        XCTAssertTrue(document.objects.isEmpty)
    }

    func testObjectsForScreenFiltersByScreen() {
        let document = DrawingDocument()
        document.add(sampleStroke(screen: 1))
        document.add(sampleStroke(screen: 2))
        XCTAssertEqual(document.objects(for: 1).count, 1)
        XCTAssertEqual(document.objects(for: 2).count, 1)
    }

    func testUndoOnEmptyDocumentIsNoOp() {
        let document = DrawingDocument()
        var changeCount = 0
        document.onChange = { changeCount += 1 }
        document.undo()
        XCTAssertTrue(document.objects.isEmpty)
        XCTAssertEqual(changeCount, 0, "onChange should not fire when undo has nothing to do")
    }

    func testRedoWithEmptyRedoStackIsNoOp() {
        let document = DrawingDocument()
        document.add(sampleStroke())
        var changeCount = 0
        document.onChange = { changeCount += 1 }
        document.redo()
        XCTAssertEqual(document.objects.count, 1, "redo should be a no-op when nothing was undone")
        XCTAssertEqual(changeCount, 0)
    }

    func testClearOnEmptyDocumentDoesNotFireOnChange() {
        let document = DrawingDocument()
        var changeCount = 0
        document.onChange = { changeCount += 1 }
        document.clear()
        XCTAssertEqual(changeCount, 0, "onChange should not fire when clear has nothing to do")
    }

    func testAddFiresOnChangeExactlyOnce() {
        let document = DrawingDocument()
        var changeCount = 0
        document.onChange = { changeCount += 1 }
        document.add(sampleStroke())
        XCTAssertEqual(changeCount, 1)
    }

    func testOnChangeFiresForUndoRedoAndClear() {
        let document = DrawingDocument()
        document.add(sampleStroke())
        var changeCount = 0
        document.onChange = { changeCount += 1 }
        document.undo()
        document.redo()
        document.clear()
        XCTAssertEqual(changeCount, 3)
    }

    func testAddAfterUndoDiscardsOnlyTheUndoneObject() {
        let document = DrawingDocument()
        document.add(sampleStroke(screen: 1))
        document.add(sampleStroke(screen: 2))
        document.undo()
        document.add(sampleStroke(screen: 3))
        XCTAssertEqual(document.objects.map(\.screen), [1, 3])
    }

    func testMultipleUndoRedoPreservesOriginalOrder() {
        let document = DrawingDocument()
        document.add(sampleStroke(screen: 1))
        document.add(sampleStroke(screen: 2))
        document.add(sampleStroke(screen: 3))

        document.undo()
        document.undo()
        document.redo()
        document.redo()

        XCTAssertEqual(document.objects.map(\.screen), [1, 2, 3], "undo/redo pairs should restore the exact original order")
    }

    func testUndoRedoRoundTripIsIdempotentOnObjectIdentity() {
        let document = DrawingDocument()
        let stroke = sampleStroke()
        document.add(stroke)
        document.undo()
        document.redo()
        XCTAssertEqual(document.objects.first?.id, stroke.id, "redo must restore the same object, not a new one")
    }

    func testObjectsForScreenReturnsEmptyWhenNoMatch() {
        let document = DrawingDocument()
        document.add(sampleStroke(screen: 1))
        XCTAssertTrue(document.objects(for: 99).isEmpty)
    }

    // MARK: - remove(id:) / onAdd (auto-fade support)

    func testRemoveByIDRemovesOnlyThatObject() {
        let document = DrawingDocument()
        let first = sampleStroke(screen: 1)
        let second = sampleStroke(screen: 2)
        let third = sampleStroke(screen: 3)
        document.add(first)
        document.add(second)
        document.add(third)
        document.remove(id: second.id)
        XCTAssertEqual(document.objects.map(\.id), [first.id, third.id])
    }

    func testRemoveByIDDoesNotFeedTheRedoStack() {
        let document = DrawingDocument()
        let stroke = sampleStroke()
        document.add(stroke)
        document.remove(id: stroke.id)
        document.redo()
        XCTAssertTrue(document.objects.isEmpty, "an auto-fade removal must not become redoable")
    }

    func testRemoveByIDLeavesUndoHistoryForOtherObjectsIntact() {
        let document = DrawingDocument()
        let first = sampleStroke(screen: 1)
        let second = sampleStroke(screen: 2)
        document.add(first)
        document.add(second)
        document.remove(id: first.id)
        document.undo()
        XCTAssertTrue(document.objects.isEmpty, "undo after a removal should still take back the last drawn object")
    }

    func testRemoveOfUnknownIDIsNoOp() {
        let document = DrawingDocument()
        document.add(sampleStroke())
        var changeCount = 0
        document.onChange = { changeCount += 1 }
        document.remove(id: UUID())
        XCTAssertEqual(document.objects.count, 1)
        XCTAssertEqual(changeCount, 0, "onChange should not fire when remove has nothing to do")
    }

    func testRemoveFiresOnChange() {
        let document = DrawingDocument()
        let stroke = sampleStroke()
        document.add(stroke)
        var changeCount = 0
        document.onChange = { changeCount += 1 }
        document.remove(id: stroke.id)
        XCTAssertEqual(changeCount, 1)
    }

    // MARK: - translate(id:by:) (move tool)

    func testTranslateShiftsEveryStrokePointAndPreservesIdentity() {
        let document = DrawingDocument()
        let stroke = sampleStroke()
        document.add(stroke)
        document.translate(id: stroke.id, by: CGPoint(x: 10, y: -5))
        guard case .stroke(let moved)? = document.objects.first else {
            return XCTFail("expected the stroke to still be there")
        }
        XCTAssertEqual(moved.id, stroke.id, "moving must not mint a new object identity")
        XCTAssertEqual(moved.points, [CGPoint(x: 10, y: -5), CGPoint(x: 11, y: -4)])
    }

    func testTranslateKeepsPaintOrder() {
        let document = DrawingDocument()
        let first = sampleStroke(screen: 1)
        let second = sampleStroke(screen: 2)
        document.add(first)
        document.add(second)
        document.translate(id: first.id, by: CGPoint(x: 1, y: 1))
        XCTAssertEqual(document.objects.map(\.id), [first.id, second.id], "moving must not reorder objects")
    }

    func testTranslateOfUnknownIDIsNoOp() {
        let document = DrawingDocument()
        document.add(sampleStroke())
        var changeCount = 0
        document.onChange = { changeCount += 1 }
        document.translate(id: UUID(), by: CGPoint(x: 1, y: 1))
        XCTAssertEqual(changeCount, 0)
    }

    func testTranslateDoesNotDisturbUndoRedo() {
        let document = DrawingDocument()
        let stroke = sampleStroke()
        document.add(stroke)
        document.undo()
        // Translating something else (no-op here) must not clear the redo stack.
        document.translate(id: UUID(), by: CGPoint(x: 1, y: 1))
        document.redo()
        XCTAssertEqual(document.objects.first?.id, stroke.id)
    }

    func testOnAddFiresForAddButNotForRedo() {
        let document = DrawingDocument()
        var addedIDs: [UUID] = []
        document.onAdd = { addedIDs.append($0.id) }
        let stroke = sampleStroke()
        document.add(stroke)
        document.undo()
        document.redo()
        XCTAssertEqual(addedIDs, [stroke.id], "redo revives an object; it must not restart its auto-fade clock")
    }

    func testObjectsForScreenPreservesInsertionOrder() {
        let document = DrawingDocument()
        document.add(sampleStroke(screen: 1))
        document.add(sampleStroke(screen: 2))
        let second = sampleStroke(screen: 1)
        document.add(second)
        XCTAssertEqual(document.objects(for: 1).last?.id, second.id)
    }
}
