import AppKit
import XCTest
@testable import paintestCore

/// `TextToolEditorView.keyDown(with:)` (issue #42) only reads `event
/// .keyCode`/`event.modifierFlags` — it's exercised here by calling it
/// directly on a standalone instance, bypassing any real window/first-
/// responder machinery, the same "a dummy event is good enough when the
/// method under test never reads window/responder state" shortcut
/// `LayerPanelViewTests`' own `dummyMouseDownEvent()` (`windowNumber: 0`)
/// already takes.
final class TextToolEditorViewTests: XCTestCase {
    private func makeEditor() -> TextToolEditorView {
        TextToolEditorView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    }

    /// Same shape as `CanvasViewTests`' own `keyDownEvent(keyCode:in:)`,
    /// extended with a `modifierFlags` parameter that helper doesn't have
    /// (issue #42 test-design review: needed here for Cmd+Return) — and
    /// `windowNumber: 0` instead of a real `NSWindow`, since
    /// `TextToolEditorView.keyDown(with:)` never reads it either.
    private func keyDownEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testKeyDown_escape_firesOnCancel_notOnCommit() {
        let editor = makeEditor()
        var cancelCount = 0
        var commitCount = 0
        editor.onCancel = { cancelCount += 1 }
        editor.onCommit = { commitCount += 1 }

        editor.keyDown(with: keyDownEvent(keyCode: 53)) // Escape

        XCTAssertEqual(cancelCount, 1, "Escape must fire onCancel")
        XCTAssertEqual(commitCount, 0, "Escape must not also fire onCommit")
    }

    func testKeyDown_cmdReturn_firesOnCommit_notOnCancel() {
        let editor = makeEditor()
        var cancelCount = 0
        var commitCount = 0
        editor.onCancel = { cancelCount += 1 }
        editor.onCommit = { commitCount += 1 }

        editor.keyDown(with: keyDownEvent(keyCode: 36, modifierFlags: .command)) // Cmd+Return

        XCTAssertEqual(commitCount, 1, "Cmd+Return must fire onCommit")
        XCTAssertEqual(cancelCount, 0, "Cmd+Return must not also fire onCancel")
    }

    func testKeyDown_plainReturn_doesNotFireOnCommitOrOnCancel() {
        // Regression guard for "素のReturnは改行のまま" (see
        // `TextToolEditorView`'s own doc comment): plain Return, with no
        // Cmd held, must fall through to `super.keyDown(with:)` (an
        // ordinary newline insertion) instead of being mistaken for the
        // Cmd+Return commit gesture.
        let editor = makeEditor()
        var cancelCount = 0
        var commitCount = 0
        editor.onCancel = { cancelCount += 1 }
        editor.onCommit = { commitCount += 1 }

        editor.keyDown(with: keyDownEvent(keyCode: 36)) // plain Return, no modifiers

        XCTAssertEqual(commitCount, 0, "plain Return must not fire onCommit")
        XCTAssertEqual(cancelCount, 0, "plain Return must not fire onCancel either")
    }

    func testKeyDown_ordinaryCharacterKey_neitherFires() {
        let editor = makeEditor()
        var cancelCount = 0
        var commitCount = 0
        editor.onCancel = { cancelCount += 1 }
        editor.onCommit = { commitCount += 1 }

        editor.keyDown(with: keyDownEvent(keyCode: 0)) // 'a' — neither Return (36/76) nor Escape (53)

        XCTAssertEqual(commitCount, 0, "an ordinary character key must not fire onCommit")
        XCTAssertEqual(cancelCount, 0, "an ordinary character key must not fire onCancel")
    }
}
