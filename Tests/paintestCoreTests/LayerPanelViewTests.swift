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
}
