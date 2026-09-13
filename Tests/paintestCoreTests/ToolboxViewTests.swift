import AppKit
import XCTest
@testable import paintestCore

final class ToolboxViewTests: XCTestCase {
    private func makeView() -> ToolboxView {
        ToolboxView()
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        for subview in view.subviews {
            if let button = subview as? NSButton {
                result.append(button)
            }
            result.append(contentsOf: allButtons(in: subview))
        }
        return result
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView { return scrollView }
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    private func findGridView(in view: NSView) -> NSGridView? {
        for subview in view.subviews {
            if let grid = subview as? NSGridView { return grid }
            if let found = findGridView(in: subview) { return found }
        }
        return nil
    }

    func testInit_doesNotCrash() {
        _ = makeView()
    }

    func testButtonCount_equals21() {
        let view = makeView()
        XCTAssertEqual(allButtons(in: view).count, 21)
    }

    func testExactlyOneButton_isPressedByDefault() {
        let view = makeView()
        let pressed = allButtons(in: view).filter { $0.state == .on }
        XCTAssertEqual(pressed.count, 1, "exactly one tool button should render pressed")
    }

    func testPressedButton_isThePencilTool() {
        let view = makeView()
        let pressed = allButtons(in: view).filter { $0.state == .on }
        XCTAssertEqual(pressed.first?.toolTip, "鉛筆")
    }

    // Pencil, eraser, pen, the eyedropper, the magnifier, the
    // rectangle/ellipse/lasso/polygon/magic-wand select tools, crop, bucket
    // fill, gradient, and text are wired to real behavior (issues #5, #10,
    // #14, #13, #11, #21, #38, #41, #42); every other button stays a purely visual
    // placeholder with no target/action, same as before. Text was
    // previously its own disabled-but-unwired placeholder (issue #43) until
    // issue #42 gave it a real implementation.
    private static let wiredToolTips: Set<String> = ["鉛筆", "消しゴム", "ペン", "スポイト", "拡大鏡", "矩形選択", "楕円選択", "投げ縄選択", "多角形選択", "マジックワンド", "切り抜き", "塗りつぶし", "グラデーション", "テキスト"]

    func testOnlyWiredTools_haveTargetAndAction() {
        let view = makeView()
        let wired = allButtons(in: view).filter { Self.wiredToolTips.contains($0.toolTip ?? "") }
        XCTAssertEqual(wired.count, 14)
        for button in wired {
            XCTAssertNotNil(button.target, "pencil/eraser/pen/eyedropper/magnifier/select tools/crop/bucket-fill/text must be wired to onToolSelected")
            XCTAssertNotNil(button.action, "pencil/eraser/pen/eyedropper/magnifier/select tools/crop/bucket-fill/text must be wired to onToolSelected")
        }
    }

    func testOtherButtons_haveNoTargetOrAction() {
        let view = makeView()
        let placeholders = allButtons(in: view).filter { !Self.wiredToolTips.contains($0.toolTip ?? "") }
        XCTAssertEqual(placeholders.count, 7)
        for button in placeholders {
            XCTAssertNil(button.target, "non-wired tool buttons are visual placeholders; wiring is out of scope")
            XCTAssertNil(button.action, "non-wired tool buttons are visual placeholders; wiring is out of scope")
        }
    }

    // MARK: - Bucket fill tool exclusive selection (issue #38)

    func testBucketFillClick_firesOnToolSelectedWithBucketFill_andTogglesPressedStates() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let bucketFill = button(toolTip: "塗りつぶし", in: view) else {
            XCTFail("could not find pencil/bucket-fill buttons")
            return
        }
        XCTAssertEqual(pencil.state, .on, "precondition: pencil starts pressed by default")
        var selected: Tool?
        view.onToolSelected = { selected = $0 }

        bucketFill.performClick(nil)

        XCTAssertEqual(selected, .bucketFill)
        XCTAssertEqual(bucketFill.state, .on)
        XCTAssertEqual(pencil.state, .off, "selecting bucket fill must turn the default-on pencil off")
    }

    func testGradientClick_firesOnToolSelectedWithGradient_andTogglesPressedStates() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let gradient = button(toolTip: "グラデーション", in: view) else {
            XCTFail("could not find pencil/gradient buttons")
            return
        }
        XCTAssertEqual(pencil.state, .on, "precondition: pencil starts pressed by default")
        var selected: Tool?
        view.onToolSelected = { selected = $0 }

        gradient.performClick(nil)

        XCTAssertEqual(selected, .gradient)
        XCTAssertEqual(gradient.state, .on)
        XCTAssertEqual(pencil.state, .off, "selecting gradient must turn the default-on pencil off")
    }

    // MARK: - Single-column layout + scroll wrapping (issue #7)

    func testToolboxIsWrappedInScrollView() {
        let view = makeView()
        XCTAssertNotNil(findScrollView(in: view), "the toolbox column should be wrapped in an NSScrollView")
    }

    func testScrollView_hasVerticalScrollerEnabled() {
        let view = makeView()
        guard let scrollView = findScrollView(in: view) else {
            XCTFail("could not find the toolbox's scroll view")
            return
        }
        XCTAssertTrue(scrollView.hasVerticalScroller, "the toolbox must scroll vertically since 21 buttons in one column run taller than the window")
    }

    func testGrid_hasSingleColumn() {
        let view = makeView()
        guard let grid = findGridView(in: view) else {
            XCTFail("could not find the toolbox's grid view")
            return
        }
        XCTAssertEqual(grid.numberOfColumns, 1, "the toolbox should be a single vertical column, matching Photoshop's layout")
    }

    // MARK: - Pencil/eraser exclusive tool selection (issue #5)
    //
    // Uses `performClick(nil)`, the same pattern `LayerPanelViewTests`
    // already uses to drive an `NSButton`'s real target/action wiring
    // without needing an actual window/event.

    private func button(toolTip: String, in view: NSView) -> NSButton? {
        allButtons(in: view).first { $0.toolTip == toolTip }
    }

    func testEraserClick_firesOnToolSelectedWithEraser_andTogglesPressedStates() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let eraser = button(toolTip: "消しゴム", in: view) else {
            XCTFail("could not find pencil/eraser buttons")
            return
        }
        var selected: Tool?
        view.onToolSelected = { selected = $0 }

        eraser.performClick(nil)

        XCTAssertEqual(selected, .eraser)
        XCTAssertEqual(eraser.state, .on)
        XCTAssertEqual(pencil.state, .off)
    }

    func testPencilClickWhileEraserIsActive_firesOnToolSelectedWithPencil_andTogglesPressedStates() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let eraser = button(toolTip: "消しゴム", in: view) else {
            XCTFail("could not find pencil/eraser buttons")
            return
        }
        eraser.performClick(nil) // switch to eraser first
        var selected: Tool?
        view.onToolSelected = { selected = $0 }

        pencil.performClick(nil)

        XCTAssertEqual(selected, .pencil)
        XCTAssertEqual(pencil.state, .on)
        XCTAssertEqual(eraser.state, .off)
    }

    func testReclickingTheAlreadyActivePencil_staysPressed_neitherButtonEndsUpOff() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let eraser = button(toolTip: "消しゴム", in: view) else {
            XCTFail("could not find pencil/eraser buttons")
            return
        }
        XCTAssertEqual(pencil.state, .on, "precondition: pencil starts pressed by default")

        pencil.performClick(nil) // re-click the already-active pencil

        XCTAssertEqual(pencil.state, .on, "re-clicking the active pencil must not toggle it off, leaving no tool pressed")
        XCTAssertEqual(eraser.state, .off)
    }

    func testRepeatedToolSwitching_alwaysLeavesExactlyOneOfPencilOrEraserPressed() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let eraser = button(toolTip: "消しゴム", in: view) else {
            XCTFail("could not find pencil/eraser buttons")
            return
        }

        eraser.performClick(nil)
        pencil.performClick(nil)
        eraser.performClick(nil)

        XCTAssertEqual(eraser.state, .on)
        XCTAssertEqual(pencil.state, .off)
    }

    // MARK: - Pen tool exclusive selection (issue #10)
    //
    // `ToolboxView` generalized its exclusive-selection bookkeeping from a
    // hardcoded pencil/eraser pair to a `[Tool: NSButton]` dictionary keyed
    // by every wired tool (issue #10), but nothing exercised the pen
    // button itself, nor a full pencil -> eraser -> pen -> pencil cycle
    // across all three wired buttons at once.

    func testPenClick_firesOnToolSelectedWithPen_andTogglesPressedStates() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let pen = button(toolTip: "ペン", in: view) else {
            XCTFail("could not find pencil/pen buttons")
            return
        }
        XCTAssertEqual(pencil.state, .on, "precondition: pencil starts pressed by default")
        var selected: Tool?
        view.onToolSelected = { selected = $0 }

        pen.performClick(nil)

        XCTAssertEqual(selected, .pen)
        XCTAssertEqual(pen.state, .on)
        XCTAssertEqual(pencil.state, .off, "selecting pen must turn the default-on pencil off")
    }

    func testCyclingThroughAllFourWiredTools_alwaysLeavesExactlyOneOfAll20ButtonsPressed() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view),
              let eraser = button(toolTip: "消しゴム", in: view),
              let pen = button(toolTip: "ペン", in: view),
              let eyedropper = button(toolTip: "スポイト", in: view) else {
            XCTFail("could not find pencil/eraser/pen/eyedropper buttons")
            return
        }

        func assertExactlyOnePressed(_ label: String) {
            let pressed = allButtons(in: view).filter { $0.state == .on }
            XCTAssertEqual(pressed.count, 1, "expected exactly one of all 21 buttons pressed after \(label)")
        }

        assertExactlyOnePressed("initial state")

        pencil.performClick(nil)
        assertExactlyOnePressed("pencil click")

        eraser.performClick(nil)
        assertExactlyOnePressed("eraser click")

        pen.performClick(nil)
        assertExactlyOnePressed("pen click")

        eyedropper.performClick(nil)
        assertExactlyOnePressed("eyedropper click")

        pencil.performClick(nil)
        assertExactlyOnePressed("pencil click again")
        XCTAssertEqual(pencil.state, .on)
        XCTAssertEqual(eraser.state, .off)
        XCTAssertEqual(pen.state, .off)
        XCTAssertEqual(eyedropper.state, .off)
    }

    func testEyedropperClick_firesOnToolSelectedWithEyedropper_andTogglesPressedStates() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let eyedropper = button(toolTip: "スポイト", in: view) else {
            XCTFail("could not find pencil/eyedropper buttons")
            return
        }
        XCTAssertEqual(pencil.state, .on, "precondition: pencil starts pressed by default")
        var selected: Tool?
        view.onToolSelected = { selected = $0 }

        eyedropper.performClick(nil)

        XCTAssertEqual(selected, .eyedropper)
        XCTAssertEqual(eyedropper.state, .on)
        XCTAssertEqual(pencil.state, .off, "selecting the eyedropper must turn the default-on pencil off")
    }

    // MARK: - Magnifier tool exclusive selection (issue #13)

    func testMagnifierClick_firesOnToolSelectedWithMagnifier_andTogglesPressedStates() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let magnifier = button(toolTip: "拡大鏡", in: view) else {
            XCTFail("could not find pencil/magnifier buttons")
            return
        }
        XCTAssertEqual(pencil.state, .on, "precondition: pencil starts pressed by default")
        var selected: Tool?
        view.onToolSelected = { selected = $0 }

        magnifier.performClick(nil)

        XCTAssertEqual(selected, .magnifier)
        XCTAssertEqual(magnifier.state, .on)
        XCTAssertEqual(pencil.state, .off, "selecting the magnifier must turn the default-on pencil off")
    }

    func testCyclingThroughAllFiveWiredTools_alwaysLeavesExactlyOneOfAll20ButtonsPressed() {
        // Extends `testCyclingThroughAllFourWiredTools_...` (issue #10) with
        // the magnifier (issue #13), now that there are five wired tools
        // instead of four. (Five more — rectangle/ellipse/lasso/polygon/
        // magic-wand select, issue #11, and crop, issue #21 — exist on the
        // toolbox now too, but aren't cycled through here; see
        // `CanvasViewTests` for their own selection-specific coverage.)
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view),
              let eraser = button(toolTip: "消しゴム", in: view),
              let pen = button(toolTip: "ペン", in: view),
              let eyedropper = button(toolTip: "スポイト", in: view),
              let magnifier = button(toolTip: "拡大鏡", in: view) else {
            XCTFail("could not find pencil/eraser/pen/eyedropper/magnifier buttons")
            return
        }

        func assertExactlyOnePressed(_ label: String) {
            let pressed = allButtons(in: view).filter { $0.state == .on }
            XCTAssertEqual(pressed.count, 1, "expected exactly one of all 21 buttons pressed after \(label)")
        }

        assertExactlyOnePressed("initial state")

        pencil.performClick(nil)
        assertExactlyOnePressed("pencil click")

        eraser.performClick(nil)
        assertExactlyOnePressed("eraser click")

        pen.performClick(nil)
        assertExactlyOnePressed("pen click")

        eyedropper.performClick(nil)
        assertExactlyOnePressed("eyedropper click")

        magnifier.performClick(nil)
        assertExactlyOnePressed("magnifier click")

        pencil.performClick(nil)
        assertExactlyOnePressed("pencil click again")
        XCTAssertEqual(pencil.state, .on)
        XCTAssertEqual(eraser.state, .off)
        XCTAssertEqual(pen.state, .off)
        XCTAssertEqual(eyedropper.state, .off)
        XCTAssertEqual(magnifier.state, .off)
    }

    // MARK: - Text tool wiring (issue #42; was a disabled placeholder under
    // issue #43)

    func testTextClick_firesOnToolSelectedWithText_andTogglesPressedStates() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view), let text = button(toolTip: "テキスト", in: view) else {
            XCTFail("could not find pencil/text buttons")
            return
        }
        XCTAssertEqual(pencil.state, .on, "precondition: pencil starts pressed by default")
        var selected: Tool?
        view.onToolSelected = { selected = $0 }

        text.performClick(nil)

        XCTAssertEqual(selected, .text)
        XCTAssertEqual(text.state, .on)
        XCTAssertEqual(pencil.state, .off, "selecting text must turn the default-on pencil off")
    }

    func testAllButtons_areEnabled() {
        // No button carries issue #43's now-obsolete `isEnabled = false`
        // special case any more.
        let view = makeView()
        let disabled = allButtons(in: view).filter { !$0.isEnabled }
        XCTAssertTrue(disabled.isEmpty, "no toolbox button should be disabled")
    }

    // Not independently unit-tested here: `Self.tools` is a private static
    // constant, so exercising `pencilIndex`'s `?? 0` fallback or
    // `buildGrid()`'s odd-count trailing row would require refactoring
    // ToolboxView to accept an injectable tool list, which is out of scope
    // for this fix (see review notes on ToolboxView.swift). Both fixes were
    // manually verified with scratch edits (reverted before commit):
    // temporarily changing the "鉛筆" label confirmed the fallback selects
    // index 0 instead of crashing, and temporarily appending another tool
    // (making the count odd) confirmed all 19 buttons render, including the
    // trailing unpaired one in its own row.
}
