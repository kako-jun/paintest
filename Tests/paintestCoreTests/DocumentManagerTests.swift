import AppKit
import XCTest
@testable import paintestCore

final class DocumentManagerTests: XCTestCase {
    private func makeDocument(_ name: String) -> Document {
        Document(layerStack: LayerStack(width: 4, height: 4), displayName: name)
    }

    func testCloseDocument_lastRemainingOne_replacesWithFreshBlankInsteadOfEmptyingList() {
        let manager = DocumentManager(initialDocument: makeDocument("only"))
        manager.closeDocument(at: 0)

        XCTAssertEqual(manager.documents.count, 1, "closing the last tab must never leave zero documents")
        XCTAssertEqual(manager.activeDocumentIndex, 0)
        XCTAssertNotEqual(manager.activeDocument.displayName, "only", "the replacement should be a fresh blank document, not the closed one")
    }

    func testCloseDocument_closingANonActiveTab_keepsTheSameDocumentActive() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c"))
        // "c" is active (index 2, the most recently added).
        XCTAssertEqual(manager.activeDocument.displayName, "c")

        // Close "a" (index 0), which sits before the active tab.
        manager.closeDocument(at: 0)

        XCTAssertEqual(manager.documents.map(\.displayName), ["b", "c"])
        XCTAssertEqual(manager.activeDocument.displayName, "c", "closing an earlier tab must not silently shift which document is active")
    }

    func testCloseDocument_closingTheActiveTab_fallsBackToANeighbor() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c"))
        manager.selectDocument(at: 1) // "b" active

        manager.closeDocument(at: 1)

        XCTAssertEqual(manager.documents.map(\.displayName), ["a", "c"])
        XCTAssertTrue(manager.activeDocument === manager.documents[manager.activeDocumentIndex])
    }

    func testAddDocument_becomesActive() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))

        XCTAssertEqual(manager.activeDocumentIndex, 1)
        XCTAssertEqual(manager.activeDocument.displayName, "b")
    }

    // MARK: - closeDocument(at:) active-tracking decision table (count x position x active/non-active)
    //
    // Issue #8 found that tracking "which index is active" numerically
    // breaks once a close shifts every index after it; `closeDocument(at:)`
    // fixed this by tracking the *previously active document itself*
    // (`===`) and re-deriving its new index after the removal. Each test
    // below pins down one row of that table so a future refactor can't
    // silently reintroduce index-based tracking.

    // #2: 2 tabs, close the active tab at the front (index 0).
    func testCloseDocument_twoTabs_closingActiveFirstTab_leavesSecondActiveAtIndexZero() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b")) // "b" active, index 1
        manager.selectDocument(at: 0) // "a" active

        manager.closeDocument(at: 0)

        XCTAssertEqual(manager.documents.map(\.displayName), ["b"])
        XCTAssertEqual(manager.activeDocumentIndex, 0)
        XCTAssertEqual(manager.activeDocument.displayName, "b")
    }

    // #3: 2 tabs, close a non-active tab at the front.
    func testCloseDocument_twoTabs_closingNonActiveFirstTab_keepsSecondActive() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b")) // "b" active, index 1

        manager.closeDocument(at: 0) // "a" is not active

        XCTAssertEqual(manager.documents.map(\.displayName), ["b"])
        XCTAssertEqual(manager.activeDocumentIndex, 0)
        XCTAssertEqual(manager.activeDocument.displayName, "b")
    }

    // #4: 2 tabs, close the active tab at the back (index 1).
    func testCloseDocument_twoTabs_closingActiveLastTab_fallsBackToFirst() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b")) // "b" active, index 1

        manager.closeDocument(at: 1)

        XCTAssertEqual(manager.documents.map(\.displayName), ["a"])
        XCTAssertEqual(manager.activeDocumentIndex, 0)
        XCTAssertEqual(manager.activeDocument.displayName, "a")
    }

    // #5: 2 tabs, close a non-active tab at the back.
    func testCloseDocument_twoTabs_closingNonActiveLastTab_keepsFirstActive() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b")) // "b" active, index 1
        manager.selectDocument(at: 0) // "a" active

        manager.closeDocument(at: 1) // "b" is not active

        XCTAssertEqual(manager.documents.map(\.displayName), ["a"])
        XCTAssertEqual(manager.activeDocumentIndex, 0)
        XCTAssertEqual(manager.activeDocument.displayName, "a")
    }

    // #6: 3 tabs, close the active tab at the front.
    func testCloseDocument_threeTabs_closingActiveFirstTab_secondBecomesActiveAtIndexZero() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c"))
        manager.selectDocument(at: 0) // "a" active

        manager.closeDocument(at: 0)

        XCTAssertEqual(manager.documents.map(\.displayName), ["b", "c"])
        XCTAssertEqual(manager.activeDocumentIndex, 0)
        XCTAssertEqual(manager.activeDocument.displayName, "b")
    }

    // #7 (strengthened): 3 tabs, close a non-active tab at the front, active
    // tab is after it. `testCloseDocument_closingANonActiveTab_...` above
    // already covers this shape but only asserts through `activeDocument`,
    // which re-derives from `activeDocumentIndex` and so can't distinguish
    // "correct index" from "wrong index that happens to still point at the
    // right document by luck". This asserts the index explicitly.
    func testCloseDocument_threeTabs_closingNonActiveFirstTab_activeIndexShiftsDownWithArray() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c")) // "c" active, index 2

        manager.closeDocument(at: 0) // "a" is not active

        XCTAssertEqual(manager.documents.map(\.displayName), ["b", "c"])
        XCTAssertEqual(manager.activeDocumentIndex, 1, "\"c\" shifted from index 2 to index 1 when \"a\" was removed ahead of it")
        XCTAssertEqual(manager.activeDocument.displayName, "c")
    }

    // #8 (strengthened): 3 tabs, close the active tab in the middle.
    // `testCloseDocument_closingTheActiveTab_fallsBackToANeighbor` above only
    // checks `activeDocument === documents[activeDocumentIndex]`, which is
    // trivially true by definition and doesn't pin down *which* document
    // ends up active. This asserts the expected document and index directly.
    func testCloseDocument_threeTabs_closingActiveMiddleTab_fallsBackToTheTabThatSlidIntoItsPlace() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c"))
        manager.selectDocument(at: 1) // "b" active

        manager.closeDocument(at: 1)

        XCTAssertEqual(manager.documents.map(\.displayName), ["a", "c"])
        XCTAssertEqual(manager.activeDocumentIndex, 1)
        XCTAssertEqual(manager.activeDocument.displayName, "c")
    }

    // #9: 3 tabs, close a non-active tab in the middle, active tab is before it.
    func testCloseDocument_threeTabs_closingNonActiveMiddleTab_activeBeforeItStaysAtSameIndex() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c"))
        manager.selectDocument(at: 0) // "a" active

        manager.closeDocument(at: 1) // "b" is not active

        XCTAssertEqual(manager.documents.map(\.displayName), ["a", "c"])
        XCTAssertEqual(manager.activeDocumentIndex, 0)
        XCTAssertEqual(manager.activeDocument.displayName, "a")
    }

    // #10 (Issue #8 regression, highest priority): 3 tabs, close a
    // non-active tab in the middle, active tab is *after* it. Naive
    // index-based tracking would leave `activeDocumentIndex` at 2 (now out
    // of range / pointing at the wrong slot); the object-identity tracking
    // must shift it down to 1 along with the array.
    func testCloseDocument_threeTabs_closingNonActiveMiddleTab_activeAfterItShiftsDownWithArray_issue8Regression() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c")) // "c" active, index 2

        manager.closeDocument(at: 1) // "b" is not active

        XCTAssertEqual(manager.documents.map(\.displayName), ["a", "c"])
        XCTAssertEqual(manager.activeDocumentIndex, 1, "issue #8 regression: \"c\" must track its own new index (1), not the stale index (2) it had before \"b\" was removed")
        XCTAssertEqual(manager.activeDocument.displayName, "c")
    }

    // #11: 3 tabs, close the active tab at the back.
    func testCloseDocument_threeTabs_closingActiveLastTab_fallsBackToNewLastTab() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c")) // "c" active, index 2

        manager.closeDocument(at: 2)

        XCTAssertEqual(manager.documents.map(\.displayName), ["a", "b"])
        XCTAssertEqual(manager.activeDocumentIndex, 1)
        XCTAssertEqual(manager.activeDocument.displayName, "b")
    }

    // #12: 3 tabs, close a non-active tab at the back, active tab is before it.
    func testCloseDocument_threeTabs_closingNonActiveLastTab_activeBeforeItStaysAtSameIndex() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))
        manager.addDocument(makeDocument("c"))
        manager.selectDocument(at: 0) // "a" active

        manager.closeDocument(at: 2) // "c" is not active

        XCTAssertEqual(manager.documents.map(\.displayName), ["a", "b"])
        XCTAssertEqual(manager.activeDocumentIndex, 0)
        XCTAssertEqual(manager.activeDocument.displayName, "a")
    }

    // MARK: - Out-of-range index guards

    func testCloseDocument_negativeIndex_isNoOp() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b"))

        manager.closeDocument(at: -1)

        XCTAssertEqual(manager.documents.map(\.displayName), ["a", "b"])
        XCTAssertEqual(manager.activeDocumentIndex, 1)
    }

    func testCloseDocument_indexAtOrBeyondCount_isNoOp() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b")) // count == 2

        manager.closeDocument(at: 2) // out of range

        XCTAssertEqual(manager.documents.map(\.displayName), ["a", "b"])
        XCTAssertEqual(manager.activeDocumentIndex, 1)
    }

    func testSelectDocument_negativeIndex_isNoOp() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b")) // "b" active, index 1

        manager.selectDocument(at: -1)

        XCTAssertEqual(manager.activeDocumentIndex, 1)
    }

    func testSelectDocument_indexAtOrBeyondCount_isNoOp() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        manager.addDocument(makeDocument("b")) // "b" active, index 1

        manager.selectDocument(at: 2) // out of range

        XCTAssertEqual(manager.activeDocumentIndex, 1)
    }

    // MARK: - closeDocument(count == 1) replacement dimensions

    func testCloseDocument_lastRemainingOne_replacementInheritsOriginalNonSquareDimensions() {
        let manager = DocumentManager(initialDocument: Document(layerStack: LayerStack(width: 30, height: 10), displayName: "wide"))

        manager.closeDocument(at: 0)

        XCTAssertEqual(manager.activeDocument.layerStack.width, 30)
        XCTAssertEqual(manager.activeDocument.layerStack.height, 10)
    }

    func testCloseDocument_lastRemainingOne_replacementInheritsTinyOnePixelDimensions() {
        let manager = DocumentManager(initialDocument: Document(layerStack: LayerStack(width: 1, height: 1), displayName: "tiny"))

        manager.closeDocument(at: 0)

        XCTAssertEqual(manager.activeDocument.layerStack.width, 1)
        XCTAssertEqual(manager.activeDocument.layerStack.height, 1)
    }

    // MARK: - addDocument edge cases

    func testAddDocument_sameFileURLTwice_createsTwoIndependentDocuments() {
        let url = URL(fileURLWithPath: "/tmp/example.paintestdoc")
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        let first = Document(layerStack: LayerStack(width: 4, height: 4), displayName: "example", fileURL: url)
        let second = Document(layerStack: LayerStack(width: 4, height: 4), displayName: "example", fileURL: url)

        manager.addDocument(first)
        manager.addDocument(second)

        XCTAssertEqual(manager.documents.count, 3)
        XCTAssertFalse(manager.documents[1] === manager.documents[2], "opening the same file twice must create two independent Document instances, not share one")
        XCTAssertEqual(manager.documents[1].fileURL, manager.documents[2].fileURL)
    }

    func testAddDocument_withNilFileURL_addsAnUnsavedDocument() {
        let manager = DocumentManager(initialDocument: makeDocument("a"))
        let unsaved = Document(layerStack: LayerStack(width: 4, height: 4), displayName: "untitled")

        manager.addDocument(unsaved)

        XCTAssertNil(manager.activeDocument.fileURL, "a newly added document with no backing file must stay unsaved (fileURL == nil)")
    }
}
