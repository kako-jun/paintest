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

    func testAllButtons_haveNoTargetOrAction() {
        let view = makeView()
        for button in allButtons(in: view) {
            XCTAssertNil(button.target, "tool buttons are visual placeholders; wiring is out of scope")
            XCTAssertNil(button.action, "tool buttons are visual placeholders; wiring is out of scope")
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
