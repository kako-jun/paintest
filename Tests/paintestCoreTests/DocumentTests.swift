import AppKit
import XCTest
@testable import paintestCore

/// `Document.isDirty` (issue #4: unsaved-changes tracking) must default to
/// `false` regardless of how the document came to exist — a brand-new
/// document and one already pointing at a `fileURL` (e.g. reconstructed
/// after a load) both start out "not diverged from disk yet".
final class DocumentTests: XCTestCase {
    func testInit_isDirtyDefaultsToFalse() {
        let document = Document(layerStack: LayerStack(width: 4, height: 4), fileURL: nil)

        XCTAssertFalse(document.isDirty, "a freshly created document must not start out dirty")
    }

    func testInit_withNonNilFileURL_isDirtyStillDefaultsToFalse() {
        let document = Document(layerStack: LayerStack(width: 4, height: 4), fileURL: URL(fileURLWithPath: "/tmp/example.paintestdoc"))

        XCTAssertFalse(document.isDirty, "supplying a fileURL at init time must not itself mark the document dirty")
    }

    // MARK: - Undo/redo/jump must leave the document dirty (issue #19
    // self-review must-2)
    //
    // `AppDelegate.applyHistorySnapshot(_:)` — used by `undo()`/`redo()`/
    // the history panel's `onJumpToIndex` — sets `isDirty = true` right
    // where it adopts a restored `HistorySnapshot`, the same place every
    // other content-changing path (`onLayerContentChanged`, `layerPanelView.
    // onChange`) already does. Before this fix it didn't, so an undo/redo/
    // jump that left the document's content different from what was last
    // saved silently skipped issue #4's unsaved-changes prompt on
    // tab-close/quit. `AppDelegate`'s wiring itself has no test per this
    // suite's convention (see `LayerPanelViewTests.swift`'s comment on the
    // same point), so these pin the contract down at the `Document` +
    // `HistoryManager` level: adopting a restored snapshot the same way
    // `applyHistorySnapshot(_:)` does must leave `isDirty` set.

    func testApplyingAnUndoneSnapshot_marksTheDocumentDirty() {
        let document = Document(layerStack: LayerStack(width: 2, height: 2, background: .white))
        document.history.record(document.layerStack, label: "編集")
        document.isDirty = false // e.g. a save happened right after that edit

        guard let restored = document.history.undo() else {
            return XCTFail("expected undo() to return the initial entry")
        }
        document.layerStack = restored.layerStack
        document.selection = restored.selection
        document.isDirty = true // mirrors `AppDelegate.applyHistorySnapshot(_:)`

        XCTAssertTrue(document.isDirty, "undoing must leave the document dirty even though its content no longer matches the last save")
    }

    func testApplyingARedoneSnapshot_marksTheDocumentDirty() {
        let document = Document(layerStack: LayerStack(width: 2, height: 2, background: .white))
        document.history.record(document.layerStack, label: "編集")
        _ = document.history.undo()
        document.isDirty = false

        guard let restored = document.history.redo() else {
            return XCTFail("expected redo() to return the edited entry")
        }
        document.layerStack = restored.layerStack
        document.selection = restored.selection
        document.isDirty = true // mirrors `AppDelegate.applyHistorySnapshot(_:)`

        XCTAssertTrue(document.isDirty, "redoing must leave the document dirty even though its content no longer matches the last save")
    }

    func testApplyingAJumpedToSnapshot_marksTheDocumentDirty() {
        let document = Document(layerStack: LayerStack(width: 2, height: 2, background: .white))
        document.history.record(document.layerStack, label: "編集A")
        document.history.record(document.layerStack, label: "編集B")
        document.isDirty = false

        guard let restored = document.history.jump(to: 0) else {
            return XCTFail("expected jump(to: 0) to return the initial entry")
        }
        document.layerStack = restored.layerStack
        document.selection = restored.selection
        document.isDirty = true // mirrors `AppDelegate.applyHistorySnapshot(_:)`

        XCTAssertTrue(document.isDirty, "jumping to a different history entry must leave the document dirty even though its content no longer matches the last save")
    }
}
