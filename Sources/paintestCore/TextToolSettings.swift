import AppKit

/// The text tool's adjustable settings (issue #42): font family, size, and
/// writing direction — shared, app-wide state analogous to
/// `PenBrushSettings`, kept directly on `CanvasView` with no separate
/// `AppDelegate` copy (same "one tool's own adjustable setting" pattern as
/// `CanvasView.magicWandTolerance`/`bucketFillTolerance`). Color is
/// deliberately not part of this struct: the text tool paints with the
/// existing foreground-color state, same as the pencil/pen (see
/// `CanvasView.rasterizeText(_:at:)`), rather than carrying a color of its
/// own.
///
/// Scope, per issue #42: a single font and a single size for the whole
/// text block (no per-character/run formatting) — matching how the overlay
/// editor (`CanvasView.beginTextEdit(at:)`) is plain-text (`isRichText =
/// false`), not a rich-text field.
struct TextToolSettings {
    /// A font family name, as vended by `NSFontManager.shared
    /// .availableFontFamilies` and resolved back to a concrete `NSFont` via
    /// `NSFontManager.shared.font(withFamily:traits:weight:size:)` (see
    /// `CanvasView.resolvedFont(family:size:)`) — not a PostScript name, so
    /// it matches what `OptionBarView.showTextOptions`'s font popup lists
    /// and lets the user pick from directly.
    var fontFamily: String = NSFont.systemFont(ofSize: 0).familyName ?? "Helvetica"
    /// Font size, in canvas pixels — not view points. The baked-in text is
    /// always this many canvas pixels tall regardless of `CanvasView
    /// .zoomScale`, matching how every other tool here paints in
    /// pixel-space rather than view-space: the on-screen overlay editor
    /// itself is shown scaled up by `zoomScale` for comfortable typing (see
    /// `beginTextEdit(at:)`), but `rasterizeText(_:at:)` always renders at
    /// this literal pixel size before compositing it onto the layer.
    var fontSize: CGFloat = 24
    /// `false` (default): horizontal writing, left to right. `true`:
    /// vertical writing (`NSTextView.layoutOrientation = .vertical`), top
    /// to bottom.
    var isVertical: Bool = false

    /// A reasonable slider span for `fontSize` in `OptionBarView
    /// .showTextOptions` — `6` (small but still legible at typical
    /// pixel-art canvas sizes) through `200` (large, page-filling display
    /// text). Not a hard content limit, just the UI's own range, same as
    /// `PenBrushSettings.sizeRange`'s role for the pen tool.
    static let fontSizeRange: ClosedRange<CGFloat> = 6...200
}
