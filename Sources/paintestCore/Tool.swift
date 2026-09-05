import Foundation

/// The currently selected paint tool. Foreground/background color and the
/// active tool are shared, app-wide state — not per-`Document`, unlike zoom
/// (issue #15) — matching classic Paint/Photoshop's single current-tool
/// model (issue #5).
///
/// Only `pencil` and `eraser` are wired to real behavior so far;
/// `ToolboxView`'s other 14 buttons stay purely visual placeholders until
/// their own issues give them real tool implementations.
enum Tool {
    case pencil
    case eraser
}
