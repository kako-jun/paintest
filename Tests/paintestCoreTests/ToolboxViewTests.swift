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
