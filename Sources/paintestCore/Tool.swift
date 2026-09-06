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
    /// Drags out a rectangular selection instead of painting (issue #11,
    /// round 1 of 3 — lasso/polygon/magic-wand selections are separate
    /// rounds, not added here). See `CanvasView`'s
    /// `mouseDown`/`mouseDragged`/`mouseUp` handling and `SelectionMask`.
    case rectangleSelect
    /// Drags out an elliptical selection instead of painting (issue #11,
    /// round 1 of 3). Same handling as `rectangleSelect`, just backed by
    /// `SelectionMask.ellipse(...)` instead of `SelectionMask.rectangle(...)`.
    case ellipseSelect
    /// Drags out a free-form selection instead of painting (issue #11,
    /// round 2 of 3): the mouse-down/dragged points accumulate into a path
    /// that's closed automatically (start joined to end) and scan-converted
    /// with `SelectionMask.polygon(...)` on mouse-up. See `CanvasView`'s
    /// `mouseDown`/`mouseDragged`/`mouseUp` handling.
    case lassoSelect
    /// Places selection vertices one click at a time instead of painting
    /// (issue #11, round 2 of 3) — a click-based state machine independent
    /// of `lassoSelect`'s drag-based one, closed either by clicking near the
    /// first vertex or pressing Return, and cancelable with Escape. See
    /// `CanvasView`'s `mouseDown`/`keyDown` handling.
    case polygonSelect
    /// Clicks a starting pixel and flood-fills outward by color similarity
    /// instead of painting (issue #11, round 3 of 3 — the last of the five
    /// selection tools). Unlike the other four selection tools, this one
    /// needs no drag/multi-click gesture state of its own: a single click is
    /// the whole gesture. See `CanvasView`'s `mouseDown` handling and
    /// `SelectionMask.magicWand(...)`.
    case magicWandSelect
}
