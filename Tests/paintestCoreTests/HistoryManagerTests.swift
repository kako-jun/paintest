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
        XCTAssertEqual(blackPixel(of: restored.layerStack), 255, "undo() should have restored the white entry")

        // Mutate the *returned* stack as if it were adopted as the new live state.
        restored.layerStack.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)

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
        XCTAssertEqual(blackPixel(of: restored.layerStack), 0, "redo() should have restored the black entry")

        // Mutate the *returned* stack as if it were adopted as the new live state.
        restored.layerStack.layers[0].canvas.setPixel(x: 0, y: 0, color: NSColor.white)

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

    // MARK: - jump(to:) aliasing (issue #19 round 2, test list 1-2)

    func testJump_returnsACopy_mutatingItDoesNotCorruptAnyStoredEntry() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0: white
        stack.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)
        history.record(stack, label: "黒") // entry 1: black

        guard let jumped = history.jump(to: 0) else {
            XCTFail("expected jump(to: 0) to return entry 0")
            return
        }
        jumped.layerStack.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)

        XCTAssertEqual(blackPixel(of: history.entries[0].layerStack), 255, "mutating the jump destination's returned copy must not corrupt that stored entry")
        XCTAssertEqual(blackPixel(of: history.entries[1].layerStack), 0, "...or any other stored entry")
    }

    func testJump_thenRecord_discardsEverythingAfterTheJumpTarget() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0
        history.record(stack, label: "A") // entry 1
        history.record(stack, label: "B") // entry 2
        _ = history.jump(to: 0) // jump back to entry 0

        history.record(stack, label: "C") // must discard "A" and "B" (everything past entry 0)

        XCTAssertEqual(history.entries.map { $0.label }, ["初期状態", "C"])
        XCTAssertFalse(history.canRedo)
    }

    // MARK: - record() copy-in across two chained records (test list 3)

    func testRecord_mutatingLiveStackBetweenTwoRecords_leavesTheFirstRecordedEntryIntact() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack)
        history.record(stack, label: "A") // entry 1: white
        stack.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)
        history.record(stack, label: "B") // entry 2: black

        XCTAssertEqual(blackPixel(of: history.entries[1].layerStack), 255, "entry \"A\" must not see the edit made before recording \"B\"")
        XCTAssertEqual(blackPixel(of: history.entries[2].layerStack), 0)
    }

    // MARK: - undo()'s returned stack: layer add/remove must not reach the stored entry (test list 5)

    func testUndo_addingOrRemovingLayersOnTheReturnedStack_doesNotAffectTheStoredEntrysLayers() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        stack.addLayer() // 2 layers
        let history = HistoryManager(initialLayerStack: stack) // entry 0: 2 layers
        history.record(stack, label: "A") // entry 1: 2 layers

        guard let restored = history.undo() else {
            XCTFail("expected undo() to return entry 0")
            return
        }
        restored.layerStack.addLayer()
        restored.layerStack.removeLayer(at: 0)

        XCTAssertEqual(history.entries[0].layerStack.layers.count, 2, "adding/removing layers on the stack undo() handed back must not reach the stored entry's own layers array")
    }

    // MARK: - Normal round-trip semantics (test list 6-7)

    func testUndoRedoUndo_roundTrip_contentsStayConsistentAtEachStep() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0: white
        stack.layers[0].canvas.setPixel(x: 0, y: 0, color: .black)
        history.record(stack, label: "黒") // entry 1: black

        XCTAssertEqual(blackPixel(of: history.undo()!.layerStack), 255, "undo() -> entry 0 (white)")
        XCTAssertEqual(blackPixel(of: history.redo()!.layerStack), 0, "redo() -> entry 1 (black)")
        XCTAssertEqual(blackPixel(of: history.undo()!.layerStack), 255, "undo() again -> entry 0 (white)")
    }

    func testJump_toCurrentIndex_succeedsWithNoSideEffectOnCurrentIndex() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack)
        history.record(stack, label: "A")
        let before = history.currentIndex

        let jumped = history.jump(to: history.currentIndex)

        XCTAssertNotNil(jumped)
        XCTAssertEqual(history.currentIndex, before)
    }

    // MARK: - jump(to:) out-of-range indices (test list 8-9)

    func testJump_negativeIndex_returnsNilAndLeavesCurrentIndexUnchanged() {
        let history = HistoryManager(initialLayerStack: LayerStack(width: 2, height: 2))
        history.record(LayerStack(width: 2, height: 2), label: "A")
        let before = history.currentIndex

        XCTAssertNil(history.jump(to: -1))
        XCTAssertEqual(history.currentIndex, before)
    }

    func testJump_indexEqualToEntriesCount_returnsNilAndLeavesCurrentIndexUnchanged() {
        let history = HistoryManager(initialLayerStack: LayerStack(width: 2, height: 2))
        history.record(LayerStack(width: 2, height: 2), label: "A")
        let before = history.currentIndex

        XCTAssertNil(history.jump(to: history.entries.count))
        XCTAssertEqual(history.currentIndex, before)
    }

    // Test list 10 ("entries.count == 1 -> undo() is nil, canUndo is false") is
    // already exhaustively covered by `testInitialState_cannotUndoOrRedo`
    // above (a freshly-initialized history always has exactly 1 entry) — not
    // duplicated here.

    // MARK: - Capacity boundary values (test list 11-14)

    func testRecord_upToExactlyCapacity_noEvictionYet() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack, capacity: 3) // entry 0
        history.record(stack, label: "A") // entry 1
        history.record(stack, label: "B") // entry 2: exactly at capacity (3 entries)

        XCTAssertEqual(history.entries.map { $0.label }, ["初期状態", "A", "B"], "reaching capacity exactly must not evict yet")
    }

    func testRecord_repeatedlyBeyondCapacity_alwaysKeepsEntryCountWithinCapacityAndCurrentIndexAtTheEnd() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack, capacity: 3)
        for i in 0..<20 {
            history.record(stack, label: "記録\(i)")
            XCTAssertLessThanOrEqual(history.entries.count, 3)
            XCTAssertEqual(history.currentIndex, history.entries.count - 1)
        }
    }

    func testUndo_repeatedlyFromTheMiddle_reachesTheStart_canUndoBecomesFalse() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0
        history.record(stack, label: "A") // entry 1
        history.record(stack, label: "B") // entry 2

        _ = history.undo() // entry 1
        _ = history.undo() // entry 0

        XCTAssertEqual(history.currentIndex, 0)
        XCTAssertFalse(history.canUndo)
    }

    func testInit_capacityZeroOrNegative_isClampedToOne() {
        let zero = HistoryManager(initialLayerStack: LayerStack(width: 2, height: 2), capacity: 0)
        let negative = HistoryManager(initialLayerStack: LayerStack(width: 2, height: 2), capacity: -5)

        XCTAssertEqual(zero.capacity, 1)
        XCTAssertEqual(negative.capacity, 1)
    }

    // MARK: - Decision table: record/undo/redo/jump operation sequences (test list 15-19)

    func testDecisionTable_recordRecordJumpToOldEntryRecord_thatRecordAlsoDiscardsTheFuture() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0
        history.record(stack, label: "A") // entry 1
        history.record(stack, label: "B") // entry 2
        _ = history.jump(to: 0) // jump back to entry 0

        history.record(stack, label: "C") // discards "A" and "B"

        XCTAssertEqual(history.entries.map { $0.label }, ["初期状態", "C"])
    }

    func testDecisionTable_recordUndoUndoRedoRecord_discardsEverythingAfterTheCurrentPosition() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0
        history.record(stack, label: "A") // entry 1
        history.record(stack, label: "B") // entry 2
        _ = history.undo() // entry 1
        _ = history.undo() // entry 0
        _ = history.redo() // entry 1

        history.record(stack, label: "C") // discards "B" (it was ahead of entry 1)

        XCTAssertEqual(history.entries.map { $0.label }, ["初期状態", "A", "C"])
    }

    func testDecisionTable_jumpToStartThenEndThenUndo_undoActsRelativeToTheLastJump() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0
        history.record(stack, label: "A") // entry 1
        history.record(stack, label: "B") // entry 2
        _ = history.jump(to: 0) // jump to entry 0 (先頭)
        _ = history.jump(to: 2) // jump to entry 2 (末尾)

        let undone = history.undo() // must step back to entry 1 ("A") relative to the last jump

        XCTAssertNotNil(undone)
        XCTAssertEqual(history.currentIndex, 1)
    }

    func testDecisionTable_undoOnSingleEntryHistoryBeforeAnyRecord_failsCleanly_thenRecordWorksNormally() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0 only

        XCTAssertNil(history.undo(), "undo() on a single-entry (pre-record) history must fail without side effects")

        history.record(stack, label: "A")

        XCTAssertEqual(history.entries.map { $0.label }, ["初期状態", "A"])
        XCTAssertEqual(history.currentIndex, 1)
    }

    // MARK: - Selection recorded and restored alongside the layerStack
    // (issue #19 self-review should-3)
    //
    // Before this fix, `HistoryEntry`/`HistorySnapshot` only carried
    // `layerStack`, so a selection-only edit (e.g. "選択範囲", which never
    // changes a single pixel) recorded a snapshot byte-identical to the
    // previous one — undoing it visibly did nothing, since the selection
    // itself was never part of what got restored. `record(_:selection:
    // label:)`/`undo()`/`redo()`/`jump(to:)` now carry the selection through
    // too, making that history entry actually meaningful.

    func testRecordAndUndo_selection_isCarriedAlongsideTheLayerStackAndRestoredCorrectly() {
        let width = 8, height = 8
        let stack = LayerStack(width: width, height: height, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0: no selection

        let selectionA = SelectionMask.rectangle(x0: 0, y0: 0, x1: 2, y1: 2, width: width, height: height)
        history.record(stack, selection: selectionA, label: "選択範囲") // entry 1: selectionA

        let selectionB = SelectionMask.rectangle(x0: 4, y0: 4, x1: 6, y1: 6, width: width, height: height)
        history.record(stack, selection: selectionB, label: "選択範囲") // entry 2: selectionB

        // Currently at entry 2 ("selectionB"); undo() steps back to entry 1
        // ("selectionA") and should hand that selection back too.
        guard let undone = history.undo() else {
            return XCTFail("expected undo() to return entry 1 (selectionA)")
        }
        guard let restoredSelection = undone.selection else {
            return XCTFail("undo() must hand back the selection recorded alongside entry 1, not nil")
        }

        for y in 0..<height {
            for x in 0..<width {
                XCTAssertEqual(restoredSelection.contains(x: x, y: y), selectionA.contains(x: x, y: y), "x=\(x) y=\(y)")
            }
        }
        // ...and mutating the mask undo() handed back must not corrupt the
        // stored entry — the same copy-out contract `layerStack` already
        // has (see the "Copy-out" section above).
        restoredSelection.setSelected(true, x: width - 1, y: height - 1)
        XCTAssertFalse(history.entries[1].selection!.contains(x: width - 1, y: height - 1), "mutating the returned selection must not reach the stored entry's own selection")
    }

    func testRecord_withNoSelectionArgument_defaultsToNilAndDoesNotAffectExistingCallSites() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack)

        history.record(stack, label: "選択なしの編集") // no `selection:` argument

        XCTAssertNil(history.entries[1].selection)

        guard let undone = history.undo() else {
            return XCTFail("expected undo() to return entry 0")
        }
        XCTAssertNil(undone.selection, "entry 0 was never given a selection either")

        guard let redone = history.redo() else {
            return XCTFail("expected redo() to return entry 1")
        }
        XCTAssertNil(redone.selection, "entry 1's selection must still be nil, not some stale leftover")
    }

    func testDecisionTable_multipleJumpsBackAndForth_neverMutatesTheEntriesArrayItself() {
        let stack = LayerStack(width: 2, height: 2, background: .white)
        let history = HistoryManager(initialLayerStack: stack) // entry 0
        history.record(stack, label: "A") // entry 1
        history.record(stack, label: "B") // entry 2
        history.record(stack, label: "C") // entry 3

        _ = history.jump(to: 1) // 中間
        _ = history.jump(to: 0) // 過去
        _ = history.jump(to: 3) // 未来
        _ = history.jump(to: 2)
        _ = history.jump(to: 1)

        XCTAssertEqual(history.entries.map { $0.label }, ["初期状態", "A", "B", "C"], "jump() is non-destructive — repeated jumping must never alter the entries array itself")
    }
}
