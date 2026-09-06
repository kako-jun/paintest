import Foundation

/// The currently selected paint tool. Foreground/background color and the
/// active tool are shared, app-wide state — not per-`Document`, unlike zoom
/// (issue #15) — matching classic Paint/Photoshop's single current-tool
/// model (issue #5).
///
/// `pencil`, `eraser`, and `pen` are wired to real behavior so far;
/// `ToolboxView`'s other 13 buttons stay purely visual placeholders until
/// their own issues give them real tool implementations.
enum Tool {
    case pencil
    case eraser
    case pen
}
