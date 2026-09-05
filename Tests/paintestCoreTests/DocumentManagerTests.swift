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
}
