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

    func testButtonCount_equals16() {
        let view = makeView()
        XCTAssertEqual(allButtons(in: view).count, 16)
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

    // Pencil, eraser, and pen are wired to real behavior (issues #5, #10);
    // every other button stays a purely visual placeholder with no
    // target/action, same as before.
    private static let wiredToolTips: Set<String> = ["鉛筆", "消しゴム", "ペン"]

    func testOnlyPencilEraserAndPen_haveTargetAndAction() {
        let view = makeView()
        let wired = allButtons(in: view).filter { Self.wiredToolTips.contains($0.toolTip ?? "") }
        XCTAssertEqual(wired.count, 3)
        for button in wired {
            XCTAssertNotNil(button.target, "pencil/eraser/pen must be wired to onToolSelected")
            XCTAssertNotNil(button.action, "pencil/eraser/pen must be wired to onToolSelected")
        }
    }

    func testOtherButtons_haveNoTargetOrAction() {
        let view = makeView()
        let placeholders = allButtons(in: view).filter { !Self.wiredToolTips.contains($0.toolTip ?? "") }
        XCTAssertEqual(placeholders.count, 13)
        for button in placeholders {
            XCTAssertNil(button.target, "non-pencil/eraser/pen tool buttons are visual placeholders; wiring is out of scope")
            XCTAssertNil(button.action, "non-pencil/eraser/pen tool buttons are visual placeholders; wiring is out of scope")
        }
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
        XCTAssertTrue(scrollView.hasVerticalScroller, "the toolbox must scroll vertically since 16 buttons in one column run taller than the window")
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

    func testCyclingThroughAllThreeWiredTools_alwaysLeavesExactlyOneOfAll16ButtonsPressed() {
        let view = makeView()
        guard let pencil = button(toolTip: "鉛筆", in: view),
              let eraser = button(toolTip: "消しゴム", in: view),
              let pen = button(toolTip: "ペン", in: view) else {
            XCTFail("could not find pencil/eraser/pen buttons")
            return
        }

        func assertExactlyOnePressed(_ label: String) {
            let pressed = allButtons(in: view).filter { $0.state == .on }
            XCTAssertEqual(pressed.count, 1, "expected exactly one of all 16 buttons pressed after \(label)")
        }

        assertExactlyOnePressed("initial state")

        pencil.performClick(nil)
        assertExactlyOnePressed("pencil click")

        eraser.performClick(nil)
        assertExactlyOnePressed("eraser click")

        pen.performClick(nil)
        assertExactlyOnePressed("pen click")

        pencil.performClick(nil)
        assertExactlyOnePressed("pencil click again")
        XCTAssertEqual(pencil.state, .on)
        XCTAssertEqual(eraser.state, .off)
        XCTAssertEqual(pen.state, .off)
    }

    // Not independently unit-tested here: `Self.tools` is a private static
    // constant, so exercising `pencilIndex`'s `?? 0` fallback or
    // `buildGrid()`'s odd-count trailing row would require refactoring
    // ToolboxView to accept an injectable tool list, which is out of scope
    // for this fix (see review notes on ToolboxView.swift). Both fixes were
    // manually verified with scratch edits (reverted before commit):
    // temporarily changing the "鉛筆" label confirmed the fallback selects
    // index 0 instead of crashing, and temporarily appending a 17th tool
    // (making the count odd) confirmed all 17 buttons render, including the
    // trailing unpaired one in its own row.
}
