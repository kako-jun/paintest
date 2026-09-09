import CoreGraphics

/// The pen tool's adjustable brush parameters (issue #20: size/hardness/
/// opacity/flow) — shared, app-wide state analogous to `Tool`'s own
/// foreground/background color and active-tool state, but scoped to the pen
/// specifically rather than every tool (mirrors `CanvasView.magicWandTolerance`,
/// which is likewise a single tool's own adjustable numeric setting kept
/// directly on `CanvasView` with no separate `AppDelegate` copy — see
/// `AppDelegate.updateOptionBar(for:)`'s `.pen`/`.magicWandSelect` cases,
/// which both read straight off `canvasView`).
///
/// Defaults reproduce the pre-#20 pen exactly: `size` matches the old fixed
/// `CanvasView.penLineWidth` constant (`3`), `hardness == 1` collapses
/// `PixelCanvas.drawPenDab`'s radial falloff to zero width (a plain solid
/// disc, visually identical to the old `drawAntialiasedDot`'s `fillEllipse`),
/// and `opacity == flow == 1` reproduce full-strength single-pass painting —
/// no stroke-level cap below 100%, and no per-dab buildup below full
/// coverage. See `PixelCanvas.drawPenDab`/`compositeOverlay` and
/// `CanvasView.stampPenDab(at:)`/`flushPenStroke()` for how the four
/// settings actually apply during a stroke.
struct PenBrushSettings {
    /// Dab diameter, in points. The old pen was permanently fixed at `3`
    /// (`sizeRange` gives a slider a reasonable span either side of that).
    var size: CGFloat = 3
    /// `0` (soft: the dab fades from its very center) ... `1` (hard: the
    /// dab is solid out to its own anti-aliased edge, matching the pre-#20
    /// pen exactly) — see `PixelCanvas.drawPenDab`'s doc comment for the
    /// gradient-stop math this maps onto.
    var hardness: Double = 1.0
    /// The upper bound on a single stroke's own alpha, applied once when
    /// the stroke ends (`PixelCanvas.compositeOverlay`), regardless of how
    /// many overlapping dabs built the stroke's accumulation buffer up —
    /// re-covering the same pixel many times within one stroke can never
    /// exceed this.
    var opacity: Double = 1.0
    /// Each individual dab's own alpha (`PixelCanvas.drawPenDab`'s `alpha`
    /// argument), applied before the stroke-level `opacity` cap above —
    /// the knob that makes overlapping dabs *within* one stroke build up
    /// gradually toward `opacity` instead of every dab instantly reaching
    /// it.
    var flow: Double = 1.0

    /// A reasonable slider span for `size` — `1` (a hairline dab) through
    /// `50` (a large, page-filling brush on the app's typical small pixel-art
    /// canvas sizes). Not a hard content limit, just the UI's own range.
    static let sizeRange: ClosedRange<CGFloat> = 1...50
    /// Every other setting (`hardness`/`opacity`/`flow`) shares this same
    /// `0...1` range.
    static let unitRange: ClosedRange<Double> = 0...1
}
