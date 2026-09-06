import Foundation

/// One recorded point in a document's edit history (issue #19): a full,
/// already-deep-copied snapshot of the `LayerStack` at the moment some edit
/// gesture completed, plus a human-readable label for the (not-yet-built,
/// round 2) history panel row.
struct HistoryEntry {
    /// Always a `.copy()` of whatever `LayerStack` was live when this entry
    /// was recorded — never the live instance itself. See `HistoryManager`'s
    /// own doc comment for why this matters.
    let layerStack: LayerStack
    /// Shown by the (round 2) history panel row for this entry — e.g.
    /// "鉛筆", "選択範囲", "変形", "レイヤー操作". Round 1 records and keeps
    /// this but has no UI that reads it yet.
    let label: String
}

/// Owns one document's undo/redo history as a linear list of full
/// `LayerStack` snapshots (issue #19). A snapshot-per-edit approach was
/// chosen over a command/inverse-operation pattern: this app's edit
/// operations (pencil/eraser/pen strokes, five different selection tools,
/// layer transforms, and future ones like color adjustments) would each
/// need a correct, independently-tested inverse, which is a much larger
/// surface for subtle bugs than "keep a deep copy of the whole stack" — an
/// acceptable trade for this app's small-to-medium canvas sizes.
///
/// ⚠️ Copy-in, copy-out is the entire safety contract of this type.
/// `LayerStack`/`Layer`/`PixelCanvas` are all reference types (`class`), so
/// every boundary crossing here — `record(_:label:)` taking a snapshot in,
/// `undo()`/`redo()` handing a snapshot back out — deep-copies via
/// `LayerStack.copy()`. Skipping either side would let a later live edit
/// silently reach back into (and corrupt) a stored history entry, or let
/// editing a just-restored "live" stack silently corrupt the history entry
/// it came from — the exact class of reference-aliasing bug issue #9 already
/// caused once in this app.
final class HistoryManager {
    private(set) var entries: [HistoryEntry]
    private(set) var currentIndex: Int
    let capacity: Int

    /// Starts a fresh history for a document: a single entry holding a copy
    /// of `initialLayerStack` as it stood at document-open/creation time,
    /// labeled "初期状態" (issue #19: the ever-present entry 0 both round 2's
    /// panel and `canUndo`/`undo()` rely on to bound the history's start).
    ///
    /// `capacity` caps how many entries are kept at once (default 50, per
    /// the issue's "数十件程度"); once exceeded, the oldest entry is dropped
    /// on the next `record(_:label:)` — see that method's doc comment.
    init(initialLayerStack: LayerStack, capacity: Int = 50) {
        self.entries = [HistoryEntry(layerStack: initialLayerStack.copy(), label: "初期状態")]
        self.currentIndex = 0
        self.capacity = max(1, capacity)
    }

    var canUndo: Bool { currentIndex > 0 }
    var canRedo: Bool { currentIndex < entries.count - 1 }

    /// Records a newly completed edit. `layerStack` must be the *live*
    /// stack after the edit finished — this deep-copies it via
    /// `LayerStack.copy()` before storing it, so later live edits can never
    /// reach back into the stored entry.
    ///
    /// Any entries after `currentIndex` (i.e. states a previous `undo()`
    /// stepped back past, that were never redone) are discarded first —
    /// the standard undo/redo rule: making a new edit after undoing
    /// abandons the old "future" instead of branching it.
    ///
    /// Once `entries.count` exceeds `capacity`, the oldest entry is dropped
    /// to make room, and `currentIndex` is shifted down by one to keep
    /// pointing at the same (now shifted) entry — the newly recorded entry
    /// is always left at the end, at `currentIndex`.
    func record(_ layerStack: LayerStack, label: String) {
        let firstDiscarded = currentIndex + 1
        if firstDiscarded < entries.count {
            entries.removeSubrange(firstDiscarded...)
        }
        entries.append(HistoryEntry(layerStack: layerStack.copy(), label: label))
        currentIndex = entries.count - 1
        if entries.count > capacity {
            entries.removeFirst()
            currentIndex -= 1
        }
    }

    /// Steps back one entry and returns a deep copy of it, or `nil` if
    /// already at the oldest entry (`!canUndo`). The returned `LayerStack`
    /// is always a fresh `.copy()` — the caller is meant to adopt it as the
    /// new live stack, and editing it further must never reach back into
    /// the stored entry.
    func undo() -> LayerStack? {
        guard canUndo else { return nil }
        currentIndex -= 1
        return entries[currentIndex].layerStack.copy()
    }

    /// Steps forward one entry and returns a deep copy of it, or `nil` if
    /// already at the newest entry (`!canRedo`). Same copy-out contract as
    /// `undo()`.
    func redo() -> LayerStack? {
        guard canRedo else { return nil }
        currentIndex += 1
        return entries[currentIndex].layerStack.copy()
    }
}
