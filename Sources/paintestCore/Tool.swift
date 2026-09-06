import Foundation

/// The currently selected paint tool. Foreground/background color and the
/// active tool are shared, app-wide state — not per-`Document`, unlike zoom
/// (issue #15) — matching classic Paint/Photoshop's single current-tool
/// model (issue #5).
///
/// `pencil`, `eraser`, `pen`, `eyedropper`, and `magnifier` are wired to real
/// behavior so far; `ToolboxView`'s other 11 buttons stay purely visual
/// placeholders until their own issues give them real tool implementations.
enum Tool {
    case pencil
    case eraser
    case pen
    /// Samples a pixel's color off the canvas instead of painting one
    /// (issue #14). Photoshop-style "one-shot" tool: no drag-to-sample, no
    /// temporary switch-to-from-another-tool shortcut — see `CanvasView`'s
    /// `mouseDown`/`mouseDragged` handling.
    case eyedropper
    /// Zooms the canvas instead of painting on it (issue #13): a click
    /// zooms in one step (Option-click zooms out one step), and a drag
    /// zooms in on the best-fit level for the dragged rectangle. See
    /// `CanvasView`'s `mouseDown`/`mouseDragged`/`mouseUp` handling and
    /// `bestFitZoomLevel(forPixelSize:viewportSize:levels:)`.
    case magnifier
}
