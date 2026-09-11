import AppKit

/// The text tool's overlay editor (issue #42): a plain `NSTextView`
/// subclass that only adds Escape-to-cancel and Cmd+Return-to-commit key
/// handling on top of `NSTextView`'s normal editing behavior.
///
/// Plain Return is deliberately left untouched here, unlike how
/// `CanvasView.keyDown(with:)` intercepts Return/Escape for the crop and
/// polygon-select tools' own confirm/cancel gestures: while this view is
/// the window's first responder (i.e. for the entire duration of a text
/// edit), `CanvasView.keyDown(with:)` never runs at all, and — more
/// importantly — a text tool needs plain Return to insert an ordinary
/// newline so multi-line text keeps working, in both horizontal and
/// vertical writing direction (the issue's own "Enter conflicts with
/// vertical writing's line breaks" caveat). So the commit gesture is Cmd+
/// Return instead, kept as a deliberate, easy-to-discover modifier
/// combination rather than overloading plain Return. `CanvasView` also
/// commits on plain focus loss (see `CanvasView.textDidEndEditing(_:)`),
/// so Cmd+Return is a convenience for finishing without having to click
/// away first, not the only way to confirm.
final class TextToolEditorView: NSTextView {
    /// Fired on Escape (issue #42) — `CanvasView.cancelTextEdit()` removes
    /// this view without touching any layer pixels.
    var onCancel: (() -> Void)?
    /// Fired on Cmd+Return (issue #42) — `CanvasView.commitTextEdit()`
    /// rasterizes the currently typed text into the active layer.
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
            // Return / keypad Enter, with Command held.
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}
