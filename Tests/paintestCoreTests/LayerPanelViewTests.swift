import AppKit
import XCTest
@testable import paintestCore

/// Per this project's CLAUDE.md ("UI依存で単体テスト不可能な部分は無理にテスト化せず、
/// 実機確認に委ねる"), and per this test suite's own design notes, these
/// tests deliberately do NOT re-derive `LayerPanelView`'s full UI tree
/// (row layout, thumbnails, selection highlighting). `LayerStackTests`
/// already exhaustively covers every boundary case of `addLayer` /
/// `removeLayer` / `duplicateLayer` / `moveLayer` directly. All that's left
/// to confirm here is the thin wiring: does pressing a given button
/// actually invoke the corresponding `LayerStack` method with the expected
/// argument (observed through its effect on `layerStack`, since the
/// button's `@objc` action methods themselves are private).
///
/// The button-bar buttons are icon-only (issue #22: SF Symbols, no text
/// `title`), so lookups here go by `toolTip` — set alongside each icon's
/// `accessibilityDescription` in `LayerPanelView.makeIconButton` — instead
/// of the `title` string this suite originally matched on.
final class LayerPanelViewTests: XCTestCase {
    private func findButton(toolTip: String, in view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.toolTip == toolTip {
                return button
            }
            if let found = findButton(toolTip: toolTip, in: subview) {
                return found
            }
        }
        return nil
    }

    private func tap(_ toolTip: String, on panel: LayerPanelView, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = findButton(toolTip: toolTip, in: panel) else {
            XCTFail("could not find a button with toolTip \"\(toolTip)\"", file: file, line: line)
            return
        }
        button.performClick(nil)
    }

    // MARK: - Row-click helpers (issue #4 self-review must)
    //
    // `LayerRowView` is declared `private` inside `LayerPanelView.swift`, so
    // this file can't refer to it by name. As in `DocumentTabBarViewTests`,
    // that's fine: `Swift`'s `private` restricts name lookup, not dynamic
    // dispatch, so walking the view hierarchy through plain `NSView.subviews`
    // and calling the inherited `mouseDown(with:)` still runs the row's own
    // override. Unlike `DocumentTabBarView`'s row stack, `LayerPanelView`'s
    // `rowsStack` (the scroll view's `documentView`) holds nothing but layer
    // rows, so no extra filtering (e.g. by accessibility) is needed here.

    private func findScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView { return scrollView }
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    /// The layer rows, top to bottom (i.e. highest layer index first — see
    /// `reload()`'s "display order is the reverse of storage order" note).
    private func rows(in panel: LayerPanelView) -> [NSView] {
        guard let scrollView = findScrollView(in: panel), let documentView = scrollView.documentView else { return [] }
        return documentView.subviews
    }

    /// A `mouseDown` event good enough for `LayerRowView.mouseDown`, which
    /// ignores its argument entirely (`onSelectRow?()` — no coordinates or
    /// window needed).
    private func dummyMouseDownEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    func testAddButton_callsAddLayerOnTheLayerStack() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)

        tap("追加", on: panel)

        XCTAssertEqual(stack.layers.count, 2)
        XCTAssertEqual(stack.activeLayerIndex, 1, "addLayer() makes the new layer active")
    }

    func testRemoveButton_callsRemoveLayerAtCurrentActiveIndex() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.addLayer(name: "B")
        XCTAssertEqual(stack.activeLayerIndex, 1)
        let panel = LayerPanelView(layerStack: stack)

        tap("削除", on: panel)

        XCTAssertEqual(stack.layers.count, 1)
        XCTAssertEqual(stack.layers[0].name, "レイヤー1", "removeLayer(at: activeLayerIndex) removed \"B\", not the other layer")
    }

    func testDuplicateButton_callsDuplicateLayerAtCurrentActiveIndex() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)

        tap("複製", on: panel)

        XCTAssertEqual(stack.layers.count, 2)
        XCTAssertEqual(stack.layers[1].name, "レイヤー1 のコピー")
    }

    func testMoveUpButton_callsMoveLayerFromActiveToOneAbove() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.addLayer(name: "B") // index 1, active
        stack.addLayer(name: "C") // index 2, active
        stack.activeLayerIndex = 1 // "B" active
        let panel = LayerPanelView(layerStack: stack)

        tap("上へ", on: panel)

        XCTAssertEqual(stack.layers.map { $0.name }, ["レイヤー1", "C", "B"])
    }

    func testMoveDownButton_callsMoveLayerFromActiveToOneBelow() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.addLayer(name: "B") // index 1, active
        let panel = LayerPanelView(layerStack: stack)

        tap("下へ", on: panel)

        XCTAssertEqual(stack.layers.map { $0.name }, ["B", "レイヤー1"])
    }

    // MARK: - Selecting a row vs. changing content (issue #4 self-review must)
    //
    // PR #4's self-review found that `selectLayer(at:)` — a plain "which
    // layer is active" change, not an edit to any layer's content — was
    // firing the same `onChange` callback as add/remove/duplicate/reorder/
    // opacity, and `AppDelegate` wires `onChange` straight to
    // `document.isDirty = true`. That meant merely clicking a different row
    // in an already-saved document made it look unsaved. The fix splits the
    // callback in two; these tests pin the split down at the `LayerPanelView`
    // level (`AppDelegate`'s wiring itself has no test per this suite's
    // convention — see `AppDelegate.swift`'s comment at the wiring site).

    func testRowClick_selectingADifferentLayerFiresOnSelectionChangedOnly() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.addLayer(name: "B") // index 1, active
        stack.activeLayerIndex = 0 // "レイヤー1" active, so clicking row 0 (below) actually changes something
        let panel = LayerPanelView(layerStack: stack)
        var onChangeCount = 0
        var onSelectionChangedCount = 0
        panel.onChange = { onChangeCount += 1 }
        panel.onSelectionChanged = { onSelectionChangedCount += 1 }

        let allRows = rows(in: panel)
        XCTAssertEqual(allRows.count, 2, "precondition: two rows")
        // Display order is top-to-bottom, the reverse of `layers`' storage
        // order (see `reload()`), so row 0 is layer index 1 ("B").
        allRows[0].mouseDown(with: dummyMouseDownEvent())

        XCTAssertEqual(stack.activeLayerIndex, 1, "clicking the top row should select layer index 1 (\"B\")")
        XCTAssertEqual(onSelectionChangedCount, 1, "selecting a different layer must fire onSelectionChanged")
        XCTAssertEqual(onChangeCount, 0, "selecting a different layer must NOT fire onChange, or AppDelegate would wrongly mark the document dirty just for a selection click (issue #4 self-review must)")
    }

    func testButtonActions_fireOnChangeNotOnSelectionChanged() {
        // Cross-check the other direction: real content edits must still go
        // through `onChange`, and must not also fire `onSelectionChanged`
        // (which `AppDelegate` wires to a redraw only, no dirty flag, so a
        // real edit routed there would silently fail to mark the document
        // dirty).
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)
        var onChangeCount = 0
        var onSelectionChangedCount = 0
        panel.onChange = { onChangeCount += 1 }
        panel.onSelectionChanged = { onSelectionChangedCount += 1 }

        tap("追加", on: panel)

        XCTAssertEqual(onChangeCount, 1, "addLayerTapped is a content edit and must fire onChange")
        XCTAssertEqual(onSelectionChangedCount, 0, "addLayerTapped must not fire onSelectionChanged")
    }

    // MARK: - willChangeActiveLayer (issue #9 review must-1)
    //
    // `AppDelegate` wires this to auto-confirm an in-progress layer
    // transform before its target layer is swapped out from under it (see
    // `AppDelegate.swift`'s comment at the wiring site — no direct
    // `AppDelegate`-level test per this suite's own convention above). It
    // must fire, *before* `activeLayerIndex` actually changes, for every
    // operation that reassigns it (select a row, add/duplicate/remove a
    // layer) — but NOT for reordering (`moveLayerUpTapped`/
    // `moveLayerDownTapped`, which leave the active layer *object*
    // unchanged even though its numeric index shifts) or attribute-only
    // edits (`visibilityToggled`/`opacitySliderChanged`, which never touch
    // which layer is active).

    func testRowClick_selectingADifferentLayerFiresWillChangeActiveLayer() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.addLayer(name: "B") // index 1, active
        stack.activeLayerIndex = 0 // "レイヤー1" active, so clicking row 0 (top, "B") actually changes something
        let panel = LayerPanelView(layerStack: stack)
        var willChangeCount = 0
        panel.willChangeActiveLayer = { willChangeCount += 1 }

        let allRows = rows(in: panel)
        allRows[0].mouseDown(with: dummyMouseDownEvent())

        XCTAssertEqual(stack.activeLayerIndex, 1, "precondition: the click actually selected a different layer")
        XCTAssertEqual(willChangeCount, 1)
    }

    func testAddButton_firesWillChangeActiveLayer() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)
        var willChangeCount = 0
        panel.willChangeActiveLayer = { willChangeCount += 1 }

        tap("追加", on: panel)

        XCTAssertEqual(willChangeCount, 1)
    }

    func testDuplicateButton_firesWillChangeActiveLayer() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)
        var willChangeCount = 0
        panel.willChangeActiveLayer = { willChangeCount += 1 }

        tap("複製", on: panel)

        XCTAssertEqual(willChangeCount, 1)
    }

    func testRemoveButton_firesWillChangeActiveLayer() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.addLayer(name: "B")
        let panel = LayerPanelView(layerStack: stack)
        var willChangeCount = 0
        panel.willChangeActiveLayer = { willChangeCount += 1 }

        tap("削除", on: panel)

        XCTAssertEqual(willChangeCount, 1)
    }

    func testMoveUpAndMoveDownButtons_doNotFireWillChangeActiveLayer() {
        // Reordering shifts the active layer's numeric *index* but not the
        // active layer *object itself* (`LayerStack.moveLayer` re-resolves
        // `activeLayerIndex` to wherever the previously-active layer object
        // ended up) — not a "which layer is active" change from the user's
        // perspective, so this must not trigger an auto-confirm.
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.addLayer(name: "B") // index 1, active
        let panel = LayerPanelView(layerStack: stack)
        var willChangeCount = 0
        panel.willChangeActiveLayer = { willChangeCount += 1 }

        tap("下へ", on: panel)
        tap("上へ", on: panel)

        XCTAssertEqual(willChangeCount, 0)
    }

    /// Recursively finds the visibility checkbox (`NSButton(checkboxWithTitle:
    /// ...)`, distinguished from the button-bar's icon buttons — the only
    /// other `NSButton`s in this panel — by `toolTip`: `makeIconButton` always
    /// sets one (see `findButton(toolTip:in:)` above), `makeRow`'s checkbox
    /// never does. `NSButton.buttonType` has no Swift-visible getter
    /// (`-setButtonType:` is a setter-only Cocoa method), so this can't just
    /// check for `.switch` directly.
    private func findCheckbox(in view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.toolTip == nil { return button }
            if let found = findCheckbox(in: subview) { return found }
        }
        return nil
    }

    /// Recursively finds the opacity `NSSlider` (matching the walk-based
    /// pattern `OptionBarViewTests.toleranceSlider(in:)` uses for a slider
    /// nested a level deeper than a flat `subviews` list can reach).
    private func findSlider(in view: NSView) -> NSSlider? {
        for subview in view.subviews {
            if let slider = subview as? NSSlider { return slider }
            if let found = findSlider(in: subview) { return found }
        }
        return nil
    }

    func testVisibilityToggle_doesNotFireWillChangeActiveLayer() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)
        var willChangeCount = 0
        panel.willChangeActiveLayer = { willChangeCount += 1 }

        guard let checkbox = findCheckbox(in: panel) else {
            return XCTFail("expected to find the visibility checkbox")
        }
        checkbox.performClick(nil)

        XCTAssertEqual(willChangeCount, 0)
    }

    func testOpacitySlider_doesNotFireWillChangeActiveLayer() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)
        var willChangeCount = 0
        panel.willChangeActiveLayer = { willChangeCount += 1 }

        guard let slider = findSlider(in: panel) else {
            return XCTFail("expected to find the opacity slider")
        }
        slider.doubleValue = 50
        _ = slider.sendAction(slider.action, to: slider.target)

        XCTAssertEqual(willChangeCount, 0)
    }

    // MARK: - Blend-mode popup (issue #37)

    private func findPopUpButton(in view: NSView) -> NSPopUpButton? {
        for subview in view.subviews {
            if let popup = subview as? NSPopUpButton { return popup }
            if let found = findPopUpButton(in: subview) { return found }
        }
        return nil
    }

    func testBlendModePopup_isPopulatedWithEveryBlendMode() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)
        guard let popup = findPopUpButton(in: panel) else {
            return XCTFail("expected to find the blend-mode popup")
        }
        XCTAssertEqual(popup.itemTitles, LayerBlendMode.allCases.map(\.displayName))
    }

    func testBlendModePopup_selectingAnItem_setsTheActiveLayersBlendMode() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)
        guard let popup = findPopUpButton(in: panel) else {
            return XCTFail("expected to find the blend-mode popup")
        }
        guard let multiplyIndex = LayerBlendMode.allCases.firstIndex(of: .multiply) else {
            return XCTFail("LayerBlendMode.allCases should contain .multiply")
        }

        popup.selectItem(at: multiplyIndex)
        _ = popup.sendAction(popup.action, to: popup.target)

        XCTAssertEqual(stack.layers[0].blendMode, .multiply)
    }

    func testBlendModePopup_reflectsTheActiveLayersCurrentBlendMode() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.setBlendMode(.screen, at: 0)
        let panel = LayerPanelView(layerStack: stack)
        guard let popup = findPopUpButton(in: panel) else {
            return XCTFail("expected to find the blend-mode popup")
        }
        guard let screenIndex = LayerBlendMode.allCases.firstIndex(of: .screen) else {
            return XCTFail("LayerBlendMode.allCases should contain .screen")
        }
        XCTAssertEqual(popup.indexOfSelectedItem, screenIndex)
    }

    func testBlendModePopup_selectingAnItem_firesOnChangeNotOnSelectionChanged() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)
        var onChangeCount = 0
        var onSelectionChangedCount = 0
        panel.onChange = { onChangeCount += 1 }
        panel.onSelectionChanged = { onSelectionChangedCount += 1 }

        guard let popup = findPopUpButton(in: panel) else {
            return XCTFail("expected to find the blend-mode popup")
        }
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)

        XCTAssertEqual(onChangeCount, 1)
        XCTAssertEqual(onSelectionChangedCount, 0)
    }

    // MARK: - Drag-and-drop row reordering (issue #54)
    //
    // `LayerRowView.mouseDragged`/`mouseUp` convert the pointer's location
    // via `superview.convert(_:from: nil)`, which — like
    // `CurrentColorIndicatorViewTests`' click-hit-testing suite and
    // `CanvasViewTests`' drag suites — needs a real (even if off-screen)
    // `NSWindow` to resolve window coordinates, plus an actual Auto Layout
    // pass so the rows have non-zero frames to hit-test against.

    private func makePanelInWindow(layerNames: [String]) -> (panel: LayerPanelView, window: NSWindow, stack: LayerStack) {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        stack.layers[0].name = layerNames[0]
        for name in layerNames.dropFirst() {
            stack.addLayer(name: name)
        }
        let panel = LayerPanelView(layerStack: stack)
        panel.frame = NSRect(x: 0, y: 0, width: 220, height: 400)
        let window = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel
        panel.layoutSubtreeIfNeeded()
        return (panel, window, stack)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    /// The center of `view`'s frame, converted into `window`'s coordinate
    /// space — matching what `event.locationInWindow` carries for a real
    /// click at that spot on screen.
    private func windowCenter(of view: NSView, in window: NSWindow) -> NSPoint {
        let rectInWindow = view.convert(view.bounds, to: nil)
        return NSPoint(x: rectInWindow.midX, y: rectInWindow.midY)
    }

    /// Drives a full mouseDown → mouseDragged → mouseUp sequence on `row`:
    /// `mouseDown` at `row`'s own current center (its starting position),
    /// `mouseDragged`/`mouseUp` both at `targetPoint`. `mouseDown` and
    /// `mouseDragged` must land at different points for `LayerRowView`'s
    /// `dragThreshold` to actually be crossed — a same-point mouseDown/
    /// mouseDragged pair would look like an unmoving click, not a drag.
    private func performDrag(row: NSView, to targetPoint: NSPoint, in window: NSWindow) {
        let startPoint = windowCenter(of: row, in: window)
        row.mouseDown(with: mouseEvent(.leftMouseDown, at: startPoint, in: window))
        row.mouseDragged(with: mouseEvent(.leftMouseDragged, at: targetPoint, in: window))
        row.mouseUp(with: mouseEvent(.leftMouseUp, at: targetPoint, in: window))
    }

    func testRowDrag_droppedOntoAnotherRow_movesTheLayerToThatRowsPosition() {
        // 3 layers, bottom-to-top storage order ["レイヤー1", "B", "C"].
        // Display order (top-to-bottom) is the reverse: rows[0]="C",
        // rows[1]="B", rows[2]="レイヤー1" (see `reload()`'s own doc).
        let (panel, window, stack) = makePanelInWindow(layerNames: ["レイヤー1", "B", "C"])
        let allRows = rows(in: panel)
        XCTAssertEqual(allRows.count, 3, "precondition: three rows")

        // Drag the bottom row ("レイヤー1", layers index 0) and drop it onto
        // the top row's position ("C", layers index 2).
        let sourceRow = allRows[2]
        let targetPoint = windowCenter(of: allRows[0], in: window)
        performDrag(row: sourceRow, to: targetPoint, in: window)

        // moveLayer(from: 0, to: 2): remove "レイヤー1" (index 0) from
        // [レイヤー1, B, C] -> [B, C], then insert it back at index 2 ->
        // [B, C, レイヤー1] — "レイヤー1" now sits on top, matching where the
        // drop landed.
        XCTAssertEqual(stack.layers.map { $0.name }, ["B", "C", "レイヤー1"])
    }

    func testRowDrag_droppedOntoAnotherRow_firesOnChange() {
        let (panel, window, stack) = makePanelInWindow(layerNames: ["レイヤー1", "B", "C"])
        var onChangeCount = 0
        panel.onChange = { onChangeCount += 1 }
        let allRows = rows(in: panel)

        let sourceRow = allRows[2] // "レイヤー1"
        let targetPoint = windowCenter(of: allRows[0], in: window) // onto "C"
        performDrag(row: sourceRow, to: targetPoint, in: window)

        XCTAssertEqual(stack.layers.map { $0.name }, ["B", "C", "レイヤー1"], "precondition: the drag actually reordered")
        XCTAssertEqual(onChangeCount, 1, "a real reorder is a content edit and must fire onChange, same as the 上へ/下へ buttons")
    }

    func testRowDrag_draggedAwayAndDroppedBackOntoItsOwnRow_isANoOp() {
        let (panel, window, stack) = makePanelInWindow(layerNames: ["レイヤー1", "B", "C"])
        var onChangeCount = 0
        panel.onChange = { onChangeCount += 1 }
        let allRows = rows(in: panel)
        let namesBefore = stack.layers.map { $0.name }

        // A genuine drag (crosses the threshold, so onRowDragged/
        // onRowDragEnded do fire) that ends up released back at its own
        // starting row — must still be a no-op, not an accidental move.
        let row = allRows[1] // "B"
        let ownCenter = windowCenter(of: row, in: window)
        let elsewhere = windowCenter(of: allRows[0], in: window) // "C"'s row, just to cross dragThreshold
        row.mouseDown(with: mouseEvent(.leftMouseDown, at: ownCenter, in: window))
        row.mouseDragged(with: mouseEvent(.leftMouseDragged, at: elsewhere, in: window))
        row.mouseUp(with: mouseEvent(.leftMouseUp, at: ownCenter, in: window))

        XCTAssertEqual(stack.layers.map { $0.name }, namesBefore, "dropping a row back onto its own position must not reorder anything")
        XCTAssertEqual(onChangeCount, 0, "a no-op drag must not fire onChange")
    }

    func testRowDrag_movementBelowDragThreshold_isTreatedAsAPlainClickNotADrag() {
        // A `mouseDown` followed by `mouseUp` at (essentially) the same
        // point — no `mouseDragged` at all — is exactly what an ordinary
        // select-click looks like. It must not be mistaken for a
        // drag-and-drop reorder.
        let (panel, window, stack) = makePanelInWindow(layerNames: ["レイヤー1", "B", "C"])
        var onChangeCount = 0
        panel.onChange = { onChangeCount += 1 }
        let allRows = rows(in: panel)
        let namesBefore = stack.layers.map { $0.name }

        let row = allRows[2] // "レイヤー1"
        let point = windowCenter(of: row, in: window)
        row.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: window))
        row.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: window))

        XCTAssertEqual(stack.layers.map { $0.name }, namesBefore, "a plain click (no mouseDragged at all) must not reorder anything")
        XCTAssertEqual(onChangeCount, 0)
    }

    func testBlendModePopup_doesNotFireWillChangeActiveLayer() {
        let stack = LayerStack(width: 4, height: 4, background: .white)
        let panel = LayerPanelView(layerStack: stack)
        var willChangeCount = 0
        panel.willChangeActiveLayer = { willChangeCount += 1 }

        guard let popup = findPopUpButton(in: panel) else {
            return XCTFail("expected to find the blend-mode popup")
        }
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)

        XCTAssertEqual(willChangeCount, 0)
    }
}
