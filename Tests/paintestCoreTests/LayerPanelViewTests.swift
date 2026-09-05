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
}
