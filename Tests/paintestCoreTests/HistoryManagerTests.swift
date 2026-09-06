import AppKit
import XCTest
@testable import paintestCore

/// Minimal correctness tests for `HistoryManager` (issue #19, round 1).
/// The core risk this type introduces is reference aliasing — `LayerStack`/
/// `Layer`/`PixelCanvas` are all classes, so both `record(_:label:)` (copy
/// in) and `undo()`/`redo()` (copy out) must deep-copy, or a later live edit
/// could silently corrupt a stored history entry (or vice versa) — the same
/// bug class issue #9 already caused once in this app. These tests focus
/// specifically on that copy-in/copy-out boundary; broader observation-point
/// coverage (capacity eviction edge cases, label plumbing, etc.) is left to
/// the next pass.
final class HistoryManagerTests: XCTestCase {
    private func blackPixel(of stack: LayerStack, x: Int = 0, y: Int = 0) -> UInt8? {
        stack.layers[0].canvas.rawPixel(x: x, y: y)?.r
    }

    // MARK: - Copy-in: record() must not keep a live reference

    func testInit_snapshotsALiveCopy_laterLiveEditsDontReachTheStoredEntry() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack)

        // Edit the live stack *after* the history was initialized from it.
        stack.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)

        XCTAssertEqual(blackPixel(of: history.entries[0].layerStack), 255, "the initial snapshot must not see edits made to the live stack afterward")
        XCTAssertEqual(blackPixel(of: stack), 0, "the live stack itself should still reflect the edit")
    }

    func testRecord_copiesLayerStack_laterLiveEditsDontReachTheStoredEntry() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack)

        history.record(stack, label: "テスト")
        // Edit the live stack *after* recording it.
        stack.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)

        XCTAssertEqual(blackPixel(of: history.entries[1].layerStack), 255, "the recorded entry must not see edits made to the live stack afterward")
        XCTAssertEqual(blackPixel(of: stack), 0, "the live stack itself should still reflect the edit")
    }

    // MARK: - Copy-out: undo()/redo() must not hand back a live reference

    func testUndo_returnsACopy_mutatingItDoesNotCorruptTheStoredEntry() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0: white
        stack.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)
        history.record(stack, label: "黒に") // entry 1: black

        guard let restored = history.undo() else {
            XCTFail("expected undo() to return entry 0")
            return
        }
        XCTAssertEqual(blackPixel(of: restored), 255, "undo() should have restored the white entry")

        // Mutate the *returned* stack as if it were adopted as the new live state.
        restored.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)

        XCTAssertEqual(blackPixel(of: history.entries[0].layerStack), 255, "editing the stack undo() handed back must not corrupt the stored entry 0")
    }

    func testRedo_returnsACopy_mutatingItDoesNotCorruptTheStoredEntry() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0: white
        stack.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)
        history.record(stack, label: "黒に") // entry 1: black
        _ = history.undo() // back to entry 0

        guard let restored = history.redo() else {
            XCTFail("expected redo() to return entry 1")
            return
        }
        XCTAssertEqual(blackPixel(of: restored), 0, "redo() should have restored the black entry")

        // Mutate the *returned* stack as if it were adopted as the new live state.
        restored.layers[0].canvas.setPixel(x: 0, y: 0, color: NSColor.white)

        XCTAssertEqual(blackPixel(of: history.entries[1].layerStack), 0, "editing the stack redo() handed back must not corrupt the stored entry 1")
    }

    // MARK: - Basic undo/redo semantics

    func testInitialState_cannotUndoOrRedo() {
        let history = HistoryManager(initialLayerStack: LayerStack(width: 2, height: 2))
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.undo())
        XCTAssertNil(history.redo())
    }

    func testRecordAfterUndo_discardsTheRedoableFuture() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0
        history.record(stack, label: "A") // entry 1
        history.record(stack, label: "B") // entry 2
        _ = history.undo() // back to entry 1, canRedo == true

        history.record(stack, label: "C") // discards the old entry 2 ("B")

        XCTAssertEqual(history.entries.map { $0.label }, ["初期状態", "A", "C"])
        XCTAssertFalse(history.canRedo, "recording a new edit after undo must abandon the old redo-able future")
    }

    func testRecord_beyondCapacity_dropsTheOldestEntryAndKeepsCurrentIndexValid() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack, capacity: 2)

        history.record(stack, label: "A") // entries: [初期状態, A] — at capacity
        history.record(stack, label: "B") // exceeds capacity: drops 初期状態

        XCTAssertEqual(history.entries.map { $0.label }, ["A", "B"])
        XCTAssertEqual(history.currentIndex, history.entries.count - 1)
        XCTAssertFalse(history.canRedo)
        XCTAssertTrue(history.canUndo)
    }
}
