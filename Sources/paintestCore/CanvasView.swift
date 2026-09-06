import AppKit

/// How a newly dragged selection combines with whatever `CanvasView.selection`
/// already held before the drag started (issue #11), mirroring Photoshop's
/// modifier-key conventions: Shift adds, Option subtracts, Shift+Option
/// intersects, and no modifier replaces the old selection outright.
enum SelectionCombineMode {
    case replace
    case add
    case subtract
    case intersect
}

/// Displays a `LayerStack`'s composited image at an integer zoom factor and
/// routes mouse input into pencil strokes on the active layer.
///
/// The view is flipped (origin top-left, y grows downward) so that pixel
/// row 0 in `PixelCanvas` maps directly onto the view's top row with no
/// extra coordinate flipping anywhere in the drawing or hit-testing code.
final class CanvasView: NSView {
    private(set) var layerStack: LayerStack
    private(set) var zoomScale: Int = CanvasView.defaultZoomScale {
        didSet { onZoomChanged?(zoomScale) }
    }

    /// Foreground (primary) and background (secondary) colors, plus the
    /// active tool — shared, app-wide state that `AppDelegate` owns and
    /// keeps in sync here, not per-document state (issue #5). Replaces the
    /// old single `penColor`.
    var foregroundColor: NSColor = .black
    var backgroundColor: NSColor = .white
    var onZoomChanged: ((Int) -> Void)?
    /// Fired after a pixel-editing gesture (`mouseDown`/`mouseDragged`)
    /// writes to the active layer's canvas, so `AppDelegate` can refresh
    /// anything showing a snapshot of that layer's contents — currently
    /// `LayerPanelView`'s thumbnails, which otherwise only redraw in
    /// response to their own panel's buttons (issue #8 review S4). Follows
    /// the same callback pattern as `onZoomChanged`.
    var onLayerContentChanged: (() -> Void)?
    /// Fired when the eyedropper tool samples a pixel (issue #14):
    /// `AppDelegate` forwards the picked color straight into `setColor`, the
    /// same entry point the color palette and color picker dialog use, so
    /// foreground/background, the current-color indicator, and recent
    /// colors all update together. `isSecondary` mirrors the color model's
    /// existing foreground/background split (issue #5) — `true` when the
    /// pixel should become the background color (Option-click) rather than
    /// the foreground color.
    var onColorPicked: ((NSColor, _ isSecondary: Bool) -> Void)?

    /// Fired once a single editing gesture actually completes with the
    /// content changed (issue #19): a pencil/eraser/pen stroke's `mouseUp`
    /// (only if that stroke actually called `paint`/`paintLine` — see
    /// `paintedDuringGesture`), a rectangle/ellipse/lasso/polygon selection's
    /// confirm, a magic wand click, and a layer transform's
    /// `commitLayerTransform()`. Never fired for in-progress drag states
    /// (only once per gesture, at the end) or for a click that changed
    /// nothing. `AppDelegate` forwards `label` straight into
    /// `Document.history.record(_:label:)`.
    var onEditCompleted: ((String) -> Void)?

    /// The active selection, if any — `nil` means "no restriction", i.e. the
    /// whole canvas is editable (issue #11). `AppDelegate` keeps this in
    /// sync with `Document.selection` the same way it does `zoomScale`.
    var selection: SelectionMask? { didSet { needsDisplay = true } }

    static let zoomLevels = [1, 2, 4, 8, 16, 32]
    static let defaultZoomScale = 4
    /// The pen's fixed stroke width — the pencil paints crisp 1px-at-a-time
    /// strokes while the pen paints wider, anti-aliased ones, and this
    /// constant is what makes that difference visible on screen. This is a
    /// temporary fixed value (issue #10); a real brush-size control lands
    /// with issue #20.
    private static let penLineWidth: CGFloat = 3
    private var lastPixel: (x: Int, y: Int)?
    /// Whether `paint(at:)`/`paintLine(from:to:)` was actually invoked
    /// during the current pencil/eraser/pen gesture (issue #19) — set in
    /// `mouseDown`/`mouseDragged`'s pixel-painting fallback path (the only
    /// place those two methods are called for a content-editing tool; see
    /// `paint(at:)`'s own doc comment for why every other tool's branch
    /// returns before reaching it) and consumed once in `mouseUp` to decide
    /// whether to fire `onEditCompleted`. Reset at the start of every new
    /// `mouseDown` gesture.
    private var paintedDuringGesture = false

    /// A drag gesture below this distance (in view points) counts as a
    /// "click" for the magnifier tool rather than a rectangle drag (issue
    /// #13) — mouse-down/mouse-up rarely land on the exact same point even
    /// when the user meant a plain click.
    private static let magnifierClickThreshold: CGFloat = 4

    /// The magnifier tool's in-progress drag rectangle, in view-space
    /// coordinates — used both to draw the rubber-band overlay in `draw(_:)`
    /// and to compute the zoomed-to rectangle in `mouseUp(with:)` (issue
    /// #13). Both are `nil` outside of an active magnifier drag.
    private var magnifierDragStart: NSPoint?
    private var magnifierDragCurrent: NSPoint?

    /// The rectangle/ellipse select tools' in-progress drag, in view-space
    /// coordinates (issue #11) — same role as `magnifierDragStart`/
    /// `magnifierDragCurrent` above, but tracked separately (and drawn by
    /// its own code in `draw(_:)`) rather than reusing the magnifier's
    /// rubber-band state, since the two tools are otherwise unrelated.
    private var selectionDragStart: NSPoint?
    private var selectionDragCurrent: NSPoint?
    /// Which modifier keys were held when the selection drag started
    /// (issue #11) — captured at `mouseDown` time (matching how real
    /// selection tools read modifiers) and consumed in `mouseUp` to decide
    /// how the drawn shape combines with the existing `selection`.
    private var selectionCombineMode: SelectionCombineMode?

    /// The lasso tool's in-progress free-form path, in pixel-space
    /// coordinates (issue #11 round 2) — accumulated across one continuous
    /// `mouseDown`→`mouseDragged`→`mouseUp` gesture, then scan-converted by
    /// `SelectionMask.polygon(...)` and cleared. Unlike `selectionDragStart`/
    /// `selectionDragCurrent` above (a single rectangle/ellipse bounding
    /// box), this needs every intermediate point, not just the two
    /// endpoints.
    private var lassoVertices: [(x: Int, y: Int)] = []
    /// Same role as `selectionCombineMode`, captured at the lasso gesture's
    /// `mouseDown` and consumed at its `mouseUp`.
    private var lassoCombineMode: SelectionCombineMode?

    /// The polygon tool's placed-so-far vertices, in pixel-space coordinates
    /// (issue #11 round 2) — unlike the lasso's `lassoVertices`, this
    /// persists *across* separate `mouseDown`/`mouseUp` pairs (one click per
    /// vertex) until the shape is closed (click near the first vertex, or
    /// Return) or cancelled (Escape). Deliberately not sharing state or code
    /// with the lasso's drag-based gesture — see this tool's own doc comment
    /// on `Tool.polygonSelect`.
    private var polygonVertices: [(x: Int, y: Int)] = []
    /// The first vertex's *view-space* point (not pixel-space, unlike
    /// `polygonVertices` itself) — kept separately so the "click near the
    /// first vertex closes the shape" hit-test in `mouseDown` can compare
    /// against the exact spot clicked rather than that pixel's rounded
    /// center, which would be off by up to half a pixel's screen size (up to
    /// 16pt at the highest zoom level) and make the close-hitbox wildly
    /// inconsistent across zoom levels.
    private var polygonFirstPoint: NSPoint?
    /// Same role as `selectionCombineMode`, captured at the polygon
    /// gesture's first click and consumed when the shape closes.
    private var polygonCombineMode: SelectionCombineMode?

    /// A click within this many view points (not pixel-space, so it already
    /// scales correctly with zoom — same reasoning as
    /// `magnifierClickThreshold`) of the polygon's first vertex closes the
    /// shape instead of placing a new vertex on top of it.
    private static let polygonCloseDistance: CGFloat = 6

    /// The magic wand's color-similarity cutoff (issue #11, round 3), passed
    /// straight through to `SelectionMask.magicWand(...)`'s `tolerance`
    /// parameter — see that method's doc comment for what the number means
    /// (a sum-of-absolute-differences across R/G/B, so its useful range is
    /// roughly `0...765`). `AppDelegate` keeps `OptionBarView`'s slider in
    /// sync with this property the same way it does `zoomScale` for the
    /// magnifier. `32` is an arbitrary starting default, not a value with any
    /// particular significance.
    var magicWandTolerance: Int = 32

    /// Which handle of `activeTransform`'s rectangle a transform drag grabbed
    /// (issue #9) — `.move` for a drag started inside the rectangle (not on
    /// a handle), `.corner`/`.edge` for the 8 resize handles (round 1), and
    /// `.rotate` (round 2) for the ring just outside a corner — Photoshop's
    /// convention for "rotate the whole rectangle around its center" rather
    /// than "resize from this corner". `nil` while no transform drag is in
    /// progress (including whenever `activeTransform` itself is `nil`).
    private enum TransformHandle: Equatable {
        case move
        case corner(TransformCorner)
        case edge(TransformEdge)
        case rotate
        /// Free-transform / distort (issue #9, round 3): grabbed when
        /// `mouseDown` hits a corner handle while Option is held (Photoshop's
        /// own "hold Option, drag a corner" convention for the free-transform
        /// distort gesture) — see `mouseDown`'s conversion of `.corner` into
        /// this right after `hitTestTransformHandle` runs.
        case distort(TransformCorner)
    }

    private enum TransformCorner: CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    private enum TransformEdge: CaseIterable {
        case top, bottom, left, right
    }

    /// The selected layer's in-progress move/scale transform (issue #9,
    /// round 1 of 3 — rotation and free/distort transform are separate
    /// rounds and stay untouched here). `nil` means "not in transform mode",
    /// in which case `mouseDown`/`mouseDragged`/`mouseUp`/`keyDown` all fall
    /// straight through to their existing `activeTool`-driven behavior.
    /// Non-`nil` takes over those four unconditionally, ahead of any tool
    /// check, since transform mode preempts every other gesture (see
    /// `beginLayerTransform()`).
    private var activeTransform: LayerTransform?
    /// A snapshot of the active layer's canvas taken the moment
    /// `beginLayerTransform()` starts a transform — read from (never written
    /// to) while the transform is live, and read from again at
    /// `commitLayerTransform()` time to rasterize into the real layer
    /// canvas. Keeping this separate from `layerStack.activeLayer.canvas`
    /// (rather than transforming that buffer in place) means the confirm
    /// step never has to read and write the same buffer at once, and
    /// `cancelLayerTransform()` can throw the whole thing away without ever
    /// having touched the real layer.
    private var transformOriginalCanvas: PixelCanvas?
    /// Which handle the current transform drag grabbed, captured at
    /// `mouseDown` and consumed (read every `mouseDragged`, cleared at
    /// `mouseUp`) the same way the other tools' drag state above works.
    /// `nil` both outside of a drag and for a drag that started on neither a
    /// handle nor the rectangle's interior (a click entirely outside the
    /// transform rectangle) — such a drag is deliberately inert.
    private var transformDragHandle: TransformHandle?
    /// The transform drag's starting point, in view-space coordinates
    /// (unscaled by zoom — same convention as `selectionDragStart` etc.).
    private var transformDragStartPoint: NSPoint?
    /// `activeTransform`'s value at the moment the current drag started —
    /// every drag recomputes the new transform from this snapshot plus the
    /// total mouse movement so far, rather than incrementally accumulating
    /// per-`mouseDragged`-event deltas (which would drift under rounding and
    /// make Shift-aspect-lock's "which axis moved more" comparison depend on
    /// per-event deltas instead of the drag's overall shape).
    private var transformDragStartTransform: LayerTransform?

    /// Whether a layer transform is currently in progress (issue #9 review
    /// must-1) — `true` exactly when `activeTransform` is non-`nil`. Exposed
    /// read-only so `AppDelegate` can auto-confirm the in-progress transform
    /// before it swaps `layerStack` out from under `commitLayerTransform()`
    /// (document tab switch, new/open, drag-and-drop) or before the layer
    /// panel changes `activeLayerIndex` out from under it (select/add/
    /// duplicate/remove a layer) — see `commitLayerTransform()`'s own doc
    /// comment for why doing this *before* either of those changes actually
    /// lands is what makes the confirm land on the correct layer.
    var isTransforming: Bool { activeTransform != nil }

    /// A transform handle is hit-testable within this many *view* points of
    /// its exact position (so the hitbox stays a constant on-screen size
    /// regardless of zoom) — mirrors `magnifierClickThreshold`/
    /// `polygonCloseDistance`'s existing "small constant view-space
    /// tolerance" pattern.
    private static let transformHandleHitRadius: CGFloat = 6

    /// A click lands on the rotate handle (issue #9, round 2) when it's
    /// farther from a corner than `transformHandleHitRadius` (which still
    /// wins, for the scale handle) but no farther than this — an annulus
    /// just outside each corner's resize hitbox, matching Photoshop's
    /// convention of a corner-adjacent ring for rotation rather than a
    /// separate handle glyph.
    private static let transformRotateHandleOuterRadius: CGFloat = 14

    /// The transform rectangle never shrinks below this many canvas pixels
    /// on either axis, regardless of how far a resize handle is dragged —
    /// avoids a degenerate (zero-area or negative) rectangle, which would
    /// make `LayerTransform.corners` and the confirm-time rasterization
    /// (division by `width`/`height`) meaningless.
    private static let transformMinimumSize: Double = 4

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    var activeTool: Tool = .pencil {
        didSet {
            guard oldValue != activeTool else { return }
            // Switching tools mid-gesture would otherwise leave a stale
            // lasso path or polygon vertex list behind — most visibly for
            // the polygon tool, whose vertex list persists *across*
            // separate mouseDown/mouseUp cycles until the shape is closed or
            // cancelled (issue #11 round 2 hardening, mirroring the existing
            // `magnifierDragStart` reset at the top of `mouseDown`).
            selectionDragStart = nil
            selectionDragCurrent = nil
            selectionCombineMode = nil
            lassoVertices = []
            lassoCombineMode = nil
            polygonVertices = []
            polygonFirstPoint = nil
            polygonCombineMode = nil
            needsDisplay = true
        }
    }

    init(layerStack: LayerStack) {
        self.layerStack = layerStack
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: layerStack.width * zoomScale, height: layerStack.height * zoomScale)
    }

    /// Swaps in a whole new document (new canvas / opened file). The
    /// caller (`AppDelegate`) is responsible for pointing any other view
    /// that references the old `LayerStack` (e.g. `LayerPanelView`) at the
    /// new one too.
    func replaceLayerStack(_ newLayerStack: LayerStack) {
        layerStack = newLayerStack
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: - Zoom (always integer multiples, nearest-neighbor)

    func zoomIn() {
        if let next = CanvasView.zoomLevels.first(where: { $0 > zoomScale }) {
            zoomScale = next
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    func zoomOut() {
        if let next = CanvasView.zoomLevels.last(where: { $0 < zoomScale }) {
            zoomScale = next
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Directly sets the zoom level, bypassing the `zoomLevels` step
    /// sequence `zoomIn()`/`zoomOut()` walk. Used by `AppDelegate` to
    /// restore a document's own remembered zoom when switching tabs, since
    /// zoom is per-`Document` state rather than shared across the single
    /// `CanvasView` instance (issue #15 follow-up).
    func setZoomScale(_ newZoomScale: Int) {
        guard CanvasView.zoomLevels.contains(newZoomScale) else { return }
        zoomScale = newZoomScale
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Picks the largest of `levels` at which a pixel-space rectangle of
    /// `size` still fits entirely inside `viewportSize` (issue #13's
    /// drag-to-zoom): the magnifier tool wants the dragged rectangle to fill
    /// as much of the viewport as possible without being clipped. Pulled out
    /// as a pure function (no `NSScrollView`/`NSEvent` dependency), the same
    /// "pure function + thin runtime wrapper" split as
    /// `pixelCoordinate(forPoint:zoomScale:)`, so the selection math can be
    /// unit tested directly.
    ///
    /// Falls back to `levels.first` (the smallest zoom) when even that
    /// doesn't fit — the best effort available when the dragged rectangle is
    /// larger than the viewport can show at any supported zoom. This
    /// fallback assumes `levels` is sorted ascending: `fitting.max()` above
    /// doesn't care about order, but `levels.first` as "the smallest zoom"
    /// only holds if it is.
    static func bestFitZoomLevel(forPixelSize size: (width: Int, height: Int), viewportSize: NSSize, levels: [Int]) -> Int {
        let fitting = levels.filter { level in
            CGFloat(size.width * level) <= viewportSize.width && CGFloat(size.height * level) <= viewportSize.height
        }
        return fitting.max() ?? levels.first ?? 1
    }

    // MARK: - Layer transform (issue #9, round 1: move + scale; round 2: rotate)

    /// Enters transform mode for the active layer ("自由変形", Cmd+T — see
    /// `AppDelegate.beginLayerTransform()`). A no-op if already in transform
    /// mode (nesting two transforms on top of each other isn't a supported
    /// gesture).
    ///
    /// Snapshots the active layer's canvas into `transformOriginalCanvas`
    /// and starts `activeTransform` at the identity rectangle (the whole
    /// layer, unscaled, unrotated). Also clears every other tool's
    /// in-progress gesture state: transform mode preempts all of them (see
    /// `activeTransform`'s doc comment), and leaving a stale lasso path or
    /// polygon vertex list behind would otherwise resurface — with
    /// coordinates from before the transform — the moment transform mode
    /// ends and the old `activeTool` becomes live again.
    func beginLayerTransform() {
        guard activeTransform == nil else { return }
        transformOriginalCanvas = layerStack.activeLayer.canvas.copy()
        activeTransform = LayerTransform.identity(width: layerStack.width, height: layerStack.height)
        transformDragHandle = nil
        transformDragStartPoint = nil
        transformDragStartTransform = nil
        magnifierDragStart = nil
        magnifierDragCurrent = nil
        selectionDragStart = nil
        selectionDragCurrent = nil
        selectionCombineMode = nil
        lassoVertices = []
        lassoCombineMode = nil
        polygonVertices = []
        polygonFirstPoint = nil
        polygonCombineMode = nil
        lastPixel = nil
        needsDisplay = true
    }

    /// Confirms the in-progress transform: rasterizes `transformOriginalCanvas`
    /// through `activeTransform` into the active layer's real canvas (see
    /// `rasterizeTransform(_:from:into:)`), then leaves transform mode. A
    /// no-op unless both `activeTransform` and `transformOriginalCanvas` are
    /// set (i.e. only meaningful while actually in transform mode).
    ///
    /// Writes into `layerStack.activeLayer.canvas` — whatever `layerStack`
    /// and `activeLayerIndex` happen to be *right now*, at confirm time, not
    /// whatever they were when `beginLayerTransform()` snapshotted
    /// `transformOriginalCanvas` (issue #9 review must-1). Left unattended,
    /// switching documents or layers between begin and confirm would
    /// silently rasterize the transform onto a completely unrelated layer,
    /// clobbering its real content with no way to undo it. The actual fix
    /// is upstream of this method: `AppDelegate` calls this proactively
    /// (via `isTransforming`) the instant a document/layer switch is about
    /// to happen, while `layerStack`/`activeLayerIndex` still point at the
    /// transform's own layer — see `AppDelegate.activateActiveDocument()`
    /// and `LayerPanelView.willChangeActiveLayer`. This method itself stays
    /// simple and just writes to "whatever is active right now", trusting
    /// callers to have kept that in sync.
    func commitLayerTransform() {
        guard let transform = activeTransform, let originalCanvas = transformOriginalCanvas else { return }
        rasterizeTransform(transform, from: originalCanvas, into: layerStack.activeLayer.canvas)
        activeTransform = nil
        transformOriginalCanvas = nil
        onLayerContentChanged?()
        onEditCompleted?("変形")
        needsDisplay = true
    }

    /// Abandons the in-progress transform without touching the active
    /// layer's actual pixels — `transformOriginalCanvas` was only ever a
    /// snapshot read from, never written back to the real layer, so simply
    /// discarding both it and `activeTransform` is enough to leave the layer
    /// exactly as it was before `beginLayerTransform()`.
    func cancelLayerTransform() {
        activeTransform = nil
        transformOriginalCanvas = nil
        needsDisplay = true
    }

    /// Maps a destination-canvas pixel back through `transform`'s rectangle
    /// to the corresponding source-canvas pixel, nearest-neighbor style —
    /// the pure half of `commitLayerTransform()`'s rasterization step,
    /// pulled out so the inverse-mapping math can be unit tested directly
    /// (same "pure function + thin runtime wrapper" split as
    /// `pixelCoordinate(forPoint:zoomScale:)`). Returns `nil` when
    /// `pixel` falls outside `transform`'s rectangle — nothing to sample, the
    /// destination pixel should stay untouched (transparent, since
    /// `rasterizeTransform` clears the destination first).
    ///
    /// Round 1 only ever called this with `transform.rotation == 0`. Round 2
    /// generalizes the inverse mapping to any angle: `pixel` is first
    /// rotated by `-rotation` around the rectangle's own center (the inverse
    /// of the rotation `LayerTransform.corners` applies when placing the
    /// rectangle), recovering the pre-rotation local offset, and everything
    /// from there on is exactly round 1's axis-aligned math applied to that
    /// local offset instead of to `pixel` directly — so a `rotation == 0`
    /// transform still takes the identical code path (and produces identical
    /// results) it always did.
    static func sourcePixel(forDestination pixel: (x: Int, y: Int), transform: LayerTransform, sourceWidth: Int, sourceHeight: Int) -> (x: Int, y: Int)? {
        guard transform.width > 0, transform.height > 0 else { return nil }
        if transform.hasDistortion {
            return sourcePixelDistorted(forDestination: pixel, transform: transform, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        }
        let dx = Double(pixel.x) - transform.centerX
        let dy = Double(pixel.y) - transform.centerY
        let cosR = cos(transform.rotation)
        let sinR = sin(transform.rotation)
        // Inverse rotation (rotate by `-rotation`): `cos(-θ) == cos(θ)` and
        // `sin(-θ) == -sin(θ)`, applied to the standard 2D rotation matrix
        // `LayerTransform.corners` uses in the forward direction.
        let localX = dx * cosR + dy * sinR
        let localY = -dx * sinR + dy * cosR
        let halfWidth = transform.width / 2
        let halfHeight = transform.height / 2
        let u = (localX + halfWidth) / transform.width
        let v = (localY + halfHeight) / transform.height
        guard u >= 0, u < 1, v >= 0, v < 1 else { return nil }
        // A tiny epsilon guards against floating-point rounding pushing an
        // exact-boundary `u`/`v` (most notably the identity transform, where
        // `u * sourceWidth` should equal `pixel.x` exactly) just under the
        // true integer before truncation. Verified empirically: without this
        // nudge, round-tripping the identity transform mis-floors roughly
        // 1 in 1000 pixels at ordinary canvas sizes (landing one row/column
        // short), which would make `commitLayerTransform()` with no actual
        // transform applied silently corrupt a sprinkling of pixels instead
        // of reproducing the canvas byte-exactly.
        //
        // The same nudge can overshoot the other way for a `u`/`v` close
        // enough to (but still under) `1` — see
        // `testSourcePixel_uJustBelowOneByLessThanEpsilon_clampsToLastValidSourceColumn`
        // (issue #9 review should-4) — pushing `sourceX`/`sourceY` to
        // exactly `sourceWidth`/`sourceHeight`, one past the last valid
        // index. Clamping to `sourceWidth - 1`/`sourceHeight - 1` keeps that
        // case sampling the intended edge pixel instead of the
        // `source.rawPixel` bounds guard silently dropping it (leaving the
        // destination pixel transparent).
        let epsilon = 1e-9
        let sourceX = min(sourceWidth - 1, Int(u * Double(sourceWidth) + epsilon))
        let sourceY = min(sourceHeight - 1, Int(v * Double(sourceHeight) + epsilon))
        return (sourceX, sourceY)
    }

    /// The `hasDistortion` counterpart to the plain rotation-only inverse
    /// mapping above (round 3): `transform.corners` (already including each
    /// corner's own `distort*` offset) is treated as an arbitrary
    /// quadrilateral, modeled as `ProjectiveTransform` mapping the unit
    /// square onto it, and `pixel` is mapped back through that transform's
    /// `inverse(x:y:)` to a normalized `(u,v)` — same epsilon-guarded
    /// truncation into source pixel coordinates as the plain-rectangle path,
    /// for the same reason (see its comment above).
    ///
    /// Because `ProjectiveTransform`'s corner-order convention matches
    /// `LayerTransform.corners`'s exactly (`topLeft`→`(0,0)`, `topRight`→
    /// `(1,0)`, `bottomRight`→`(1,1)`, `bottomLeft`→`(0,1)`), and because a
    /// transform with every `distort*` offset at `.zero` makes `corners`
    /// produce the exact same rotated rectangle round 1/2's rectangle-only
    /// math already handles, this path is only ever reached once at least
    /// one `distort*` offset is non-zero — verified by
    /// `testProjectiveTransform_noDistortion_matchesPlainRectangleMapping`.
    private static func sourcePixelDistorted(forDestination pixel: (x: Int, y: Int), transform: LayerTransform, sourceWidth: Int, sourceHeight: Int) -> (x: Int, y: Int)? {
        let corners = transform.corners
        let projective = ProjectiveTransform(
            topLeft: corners.topLeft,
            topRight: corners.topRight,
            bottomRight: corners.bottomRight,
            bottomLeft: corners.bottomLeft
        )
        guard let (u, v) = projective.inverse(x: Double(pixel.x), y: Double(pixel.y)) else { return nil }
        guard u >= 0, u < 1, v >= 0, v < 1 else { return nil }
        // Same epsilon-overshoot clamp as the plain-rectangle path above
        // (issue #9 review should-4) — see its comment for why.
        let epsilon = 1e-9
        let sourceX = min(sourceWidth - 1, Int(u * Double(sourceWidth) + epsilon))
        let sourceY = min(sourceHeight - 1, Int(v * Double(sourceHeight) + epsilon))
        return (sourceX, sourceY)
    }

    /// Confirm-time rasterization (issue #9): clears `destination`, then for
    /// every destination-canvas pixel looks up its nearest-neighbor source
    /// pixel via `sourcePixel(forDestination:transform:sourceWidth:sourceHeight:)`
    /// and copies it across. Pixels outside `transform`'s rectangle are left
    /// as the clear color `destination` was just filled with.
    ///
    /// Loops over `source`'s own dimensions (the `transformOriginalCanvas`
    /// snapshot taken at `beginLayerTransform()` time), not `layerStack`'s
    /// current `width`/`height` (issue #9 review must-1, defensive
    /// hardening): the auto-confirm wiring in `AppDelegate` (see
    /// `commitLayerTransform()`'s doc comment) keeps these in lock-step in
    /// practice, but reading the loop bound from the snapshot that's
    /// actually being sampled — rather than from mutable ambient state this
    /// method doesn't otherwise touch — is the strictly correct thing to do
    /// regardless.
    private func rasterizeTransform(_ transform: LayerTransform, from source: PixelCanvas, into destination: PixelCanvas) {
        destination.fill(with: .clear)
        for y in 0..<source.height {
            for x in 0..<source.width {
                guard let sample = CanvasView.sourcePixel(forDestination: (x, y), transform: transform, sourceWidth: source.width, sourceHeight: source.height),
                      let raw = source.rawPixel(x: sample.x, y: sample.y) else { continue }
                let color = NSColor(
                    deviceRed: Double(raw.r) / 255,
                    green: Double(raw.g) / 255,
                    blue: Double(raw.b) / 255,
                    alpha: Double(raw.a) / 255
                )
                destination.setPixel(x: x, y: y, color: color)
            }
        }
    }

    /// The 8 handle positions (4 corners + 4 edge midpoints) of `transform`'s
    /// rectangle, in view-space points at `scale` — the live counterpart to
    /// `transform.corners`' canvas-pixel-space corners, used both for
    /// `hitTestTransformHandle` and for drawing the handles in `draw(_:)`.
    private static func transformHandlePoints(for transform: LayerTransform, scale: CGFloat) -> (corners: [TransformCorner: NSPoint], edges: [TransformEdge: NSPoint]) {
        let c = transform.corners
        func toView(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x * scale, y: p.y * scale) }
        let topLeft = toView(c.topLeft)
        let topRight = toView(c.topRight)
        let bottomRight = toView(c.bottomRight)
        let bottomLeft = toView(c.bottomLeft)
        func midpoint(_ a: NSPoint, _ b: NSPoint) -> NSPoint { NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let corners: [TransformCorner: NSPoint] = [
            .topLeft: topLeft, .topRight: topRight, .bottomRight: bottomRight, .bottomLeft: bottomLeft
        ]
        let edges: [TransformEdge: NSPoint] = [
            .top: midpoint(topLeft, topRight),
            .bottom: midpoint(bottomLeft, bottomRight),
            .left: midpoint(topLeft, bottomLeft),
            .right: midpoint(topRight, bottomRight)
        ]
        return (corners, edges)
    }

    /// Hit-tests a view-space click/drag-start point against `transform`'s
    /// handles and interior, at the current `zoomScale` — used by `mouseDown`
    /// while in transform mode. Corners and edge midpoints win over
    /// everything else (checked first) within `transformHandleHitRadius`
    /// view points; a click landing in the ring just outside a corner
    /// (`transformRotateHandleOuterRadius`) is `.rotate` (round 2); a point
    /// inside the rectangle but not on any handle or ring is a `.move`; a
    /// point outside the rectangle entirely is `nil` (no drag).
    private func hitTestTransformHandle(at point: NSPoint, transform: LayerTransform) -> TransformHandle? {
        let scale = CGFloat(zoomScale)
        let (corners, edges) = CanvasView.transformHandlePoints(for: transform, scale: scale)
        for corner in TransformCorner.allCases {
            if let handlePoint = corners[corner], hypot(point.x - handlePoint.x, point.y - handlePoint.y) <= Self.transformHandleHitRadius {
                return .corner(corner)
            }
        }
        for edge in TransformEdge.allCases {
            if let handlePoint = edges[edge], hypot(point.x - handlePoint.x, point.y - handlePoint.y) <= Self.transformHandleHitRadius {
                return .edge(edge)
            }
        }
        for corner in TransformCorner.allCases {
            if let handlePoint = corners[corner] {
                let distance = hypot(point.x - handlePoint.x, point.y - handlePoint.y)
                if distance > Self.transformHandleHitRadius && distance <= Self.transformRotateHandleOuterRadius {
                    return .rotate
                }
            }
        }
        // Once any corner has been distorted (round 3), the visual shape is
        // an arbitrary quadrilateral, not a rectangle — the plain
        // rotated-rectangle test below (`transform.width`/`height`/rotation`
        // only, no `distort*` offsets) would test against the wrong shape
        // entirely, hitting/missing exactly the cases
        // `testDistortedTransform_clickInsideVisualQuadButOutsideBaseRectangle_hitsMoveHandle`
        // (issue #9 review must-2) pins down. `ProjectiveTransform` already
        // models this quadrilateral exactly (`sourcePixelDistorted` above
        // uses the same construction to sample it) — a point is inside iff
        // its inverse-mapped `(u, v)` lands in `[0, 1)` on both axes, the
        // same convention `sourcePixel`'s own range guard uses. `point` is
        // in view space (scaled by `zoomScale`), but `transform.corners` —
        // and so `ProjectiveTransform`'s coordinate system — is in canvas
        // pixel space, so `point` is scaled back down before testing.
        if transform.hasDistortion {
            let corners = transform.corners
            let projective = ProjectiveTransform(
                topLeft: corners.topLeft,
                topRight: corners.topRight,
                bottomRight: corners.bottomRight,
                bottomLeft: corners.bottomLeft
            )
            let canvasX = Double(point.x) / Double(scale)
            let canvasY = Double(point.y) / Double(scale)
            guard let (u, v) = projective.inverse(x: canvasX, y: canvasY), u >= 0, u < 1, v >= 0, v < 1 else {
                return nil
            }
            return .move
        }

        // A point-in-rotated-rectangle test: transforms `point` into the
        // rectangle's own (unrotated) local frame around its center — via
        // the same inverse-rotation math as `sourcePixel(forDestination:
        // transform:sourceWidth:sourceHeight:)` — then checks it against the
        // axis-aligned half-extents there. Round 1's rectangle was never
        // rotated, so a plain axis-aligned `NSRect.contains` sufficed then;
        // this reduces to exactly that check when `rotation == 0`, and
        // handles any angle now that round 2 lets `rotation` be nonzero.
        // Only reached when `!transform.hasDistortion`, matching the
        // `sourcePixel`/`hasDistortion` split above.
        let centerView = CGPoint(x: transform.centerX * Double(scale), y: transform.centerY * Double(scale))
        let cosR = cos(transform.rotation)
        let sinR = sin(transform.rotation)
        let dx = Double(point.x) - centerView.x
        let dy = Double(point.y) - centerView.y
        let localX = dx * cosR + dy * sinR
        let localY = -dx * sinR + dy * cosR
        let halfWidth = transform.width / 2 * Double(scale)
        let halfHeight = transform.height / 2 * Double(scale)
        return (abs(localX) <= halfWidth && abs(localY) <= halfHeight) ? .move : nil
    }

    /// One axis of a resize drag: given the anchor (fixed, opposite handle)
    /// and the dragged handle's own starting coordinate on this axis, plus
    /// how far the mouse has moved along it, returns the new size and center
    /// for this axis — clamped to `transformMinimumSize` and correctly
    /// signed even if the drag crosses over the anchor (flips the rectangle).
    /// Shared by both the corner and edge/single-axis resize handlers below
    /// so the anchor-relative math lives in exactly one place.
    private static func resizedAxis(anchor: Double, draggedStart: Double, delta: Double) -> (size: Double, center: Double) {
        let raw = draggedStart + delta
        let sign: Double = raw >= anchor ? 1 : -1
        let size = max(transformMinimumSize, abs(raw - anchor))
        let newDragged = anchor + sign * size
        return (size, (anchor + newDragged) / 2)
    }

    /// Resizes `start` by dragging `corner` to `start`'s own position plus
    /// (`dx`, `dy`) view-independent canvas-pixel deltas, holding the
    /// diagonally opposite corner fixed as the anchor. `keepAspect` (Shift)
    /// locks the aspect ratio: whichever axis moved further (by raw pixel
    /// distance) drives a single scale factor applied to both axes, rather
    /// than letting each axis resize independently.
    ///
    /// `dx`/`dy` arrive in screen/canvas axes (see `mouseDragged`), but
    /// `width`/`height`/`centerX`/`centerY` describe the rectangle in its own
    /// *local*, unrotated frame — round 1 got away with feeding screen-axis
    /// deltas straight into the axis-aligned math below because `rotation`
    /// was always `0`, making the two frames identical. Round 2 lets
    /// `rotation` be nonzero, so a screen-axis drag has to be rotated by
    /// `-start.rotation` first to recover the local-frame `(localDx,
    /// localDy)` this function's math actually expects — otherwise a
    /// diagonal (screen-axis) drag on a tilted rectangle changes `width` and
    /// `height` by the wrong, screen-relative amounts and shears the
    /// rectangle into a parallelogram instead of scaling it in place. The
    /// resulting local-frame center shift is rotated back by `+start.
    /// rotation` at the end to land back in screen/canvas coordinates before
    /// being added to `centerX`/`centerY`. Both rotations are identity when
    /// `rotation == 0`, so this is byte-for-byte round 1's behavior in that
    /// case.
    private static func resizeByCorner(_ corner: TransformCorner, start: LayerTransform, dx: Double, dy: Double, keepAspect: Bool) -> LayerTransform {
        let cosR = cos(start.rotation)
        let sinR = sin(start.rotation)
        // Inverse rotation (by `-start.rotation`) — same formula
        // `sourcePixel(forDestination:transform:sourceWidth:sourceHeight:)`
        // uses to recover a local offset from a screen-space one.
        let localDx = dx * cosR + dy * sinR
        let localDy = -dx * sinR + dy * cosR

        let halfWidth = start.width / 2
        let halfHeight = start.height / 2
        // The local-frame corners, relative to the rectangle's own center —
        // i.e. exactly what `start.corners` would be if `start.rotation`
        // were `0`.
        let (draggedStart, anchor): (CGPoint, CGPoint)
        switch corner {
        case .topLeft: (draggedStart, anchor) = (CGPoint(x: -halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: halfHeight))
        case .topRight: (draggedStart, anchor) = (CGPoint(x: halfWidth, y: -halfHeight), CGPoint(x: -halfWidth, y: halfHeight))
        case .bottomRight: (draggedStart, anchor) = (CGPoint(x: halfWidth, y: halfHeight), CGPoint(x: -halfWidth, y: -halfHeight))
        case .bottomLeft: (draggedStart, anchor) = (CGPoint(x: -halfWidth, y: halfHeight), CGPoint(x: halfWidth, y: -halfHeight))
        }

        var (width, localCenterX) = resizedAxis(anchor: Double(anchor.x), draggedStart: Double(draggedStart.x), delta: localDx)
        var (height, localCenterY) = resizedAxis(anchor: Double(anchor.y), draggedStart: Double(draggedStart.y), delta: localDy)

        if keepAspect, start.width > 0, start.height > 0 {
            let scale = abs(localDx) >= abs(localDy) ? width / start.width : height / start.height
            width = max(transformMinimumSize, start.width * scale)
            height = max(transformMinimumSize, start.height * scale)
            let signX: Double = Double(draggedStart.x) + localDx >= Double(anchor.x) ? 1 : -1
            let signY: Double = Double(draggedStart.y) + localDy >= Double(anchor.y) ? 1 : -1
            localCenterX = (Double(anchor.x) + (Double(anchor.x) + signX * width)) / 2
            localCenterY = (Double(anchor.y) + (Double(anchor.y) + signY * height)) / 2
        }

        // Forward rotation (by `+start.rotation`) — same convention
        // `LayerTransform.corners` uses to place a local offset back into
        // canvas space — turning the local-frame center shift back into a
        // screen/canvas-space one before it's added to `start.centerX`/
        // `centerY` below.
        let offsetX = localCenterX * cosR - localCenterY * sinR
        let offsetY = localCenterX * sinR + localCenterY * cosR

        var result = start
        result.width = width
        result.height = height
        result.centerX = start.centerX + offsetX
        result.centerY = start.centerY + offsetY
        return result
    }

    /// Resizes `start` along a single axis by dragging `edge`'s midpoint,
    /// holding the opposite edge fixed as the anchor — left/right handles
    /// change only `width`/`centerX` (in `start`'s local frame — see below),
    /// top/bottom only `height`/`centerY`.
    ///
    /// Same local-frame rotation fix as `resizeByCorner` above: `dx`/`dy`
    /// are rotated by `-start.rotation` into the rectangle's local frame
    /// before being used as a size delta, and the resulting local-frame
    /// center shift is rotated back by `+start.rotation` into screen/canvas
    /// space before being applied to `centerX`/`centerY`. Identity in both
    /// directions when `rotation == 0`.
    private static func resizeByEdge(_ edge: TransformEdge, start: LayerTransform, dx: Double, dy: Double) -> LayerTransform {
        let cosR = cos(start.rotation)
        let sinR = sin(start.rotation)
        let localDx = dx * cosR + dy * sinR
        let localDy = -dx * sinR + dy * cosR

        let halfWidth = start.width / 2
        let halfHeight = start.height / 2

        var result = start
        switch edge {
        case .left:
            let (width, localCenterX) = resizedAxis(anchor: halfWidth, draggedStart: -halfWidth, delta: localDx)
            result.width = width
            result.centerX = start.centerX + localCenterX * cosR
            result.centerY = start.centerY + localCenterX * sinR
        case .right:
            let (width, localCenterX) = resizedAxis(anchor: -halfWidth, draggedStart: halfWidth, delta: localDx)
            result.width = width
            result.centerX = start.centerX + localCenterX * cosR
            result.centerY = start.centerY + localCenterX * sinR
        case .top:
            let (height, localCenterY) = resizedAxis(anchor: halfHeight, draggedStart: -halfHeight, delta: localDy)
            result.height = height
            result.centerX = start.centerX - localCenterY * sinR
            result.centerY = start.centerY + localCenterY * cosR
        case .bottom:
            let (height, localCenterY) = resizedAxis(anchor: -halfHeight, draggedStart: halfHeight, delta: localDy)
            result.height = height
            result.centerX = start.centerX - localCenterY * sinR
            result.centerY = start.centerY + localCenterY * cosR
        }
        return result
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // While a layer transform is in progress (issue #9), the active
        // layer's own *unmoved* pixels are left out of the base composite —
        // its live-preview block below draws them back in at the dragged
        // position instead. Everything is `nil` (no exclusion) outside of
        // transform mode, so this is byte-for-byte the same composite as
        // before issue #9 whenever `activeTransform` is `nil`.
        let excludedLayerIndex = activeTransform != nil ? layerStack.activeLayerIndex : nil
        guard let image = layerStack.compositeImage(excludingLayerAtIndex: excludedLayerIndex) else { return }

        // Dot-perfect scaling: no interpolation, no anti-aliasing, anywhere
        // in this transfer path.
        context.interpolationQuality = .none
        context.setShouldAntialias(false)

        let destRect = CGRect(
            x: 0,
            y: 0,
            width: layerStack.width * zoomScale,
            height: layerStack.height * zoomScale
        )
        context.draw(image, in: destRect)

        // Layer transform live preview + handles (issue #9; round 1: move
        // and scale; round 2: rotate too, so this rectangle is no longer
        // necessarily axis-aligned). `transformOriginalCanvas` is what
        // actually gets drawn (the layer's pixels as they were when the
        // transform began), repositioned/resized/rotated to
        // `activeTransform`'s current rectangle — together with the base
        // composite's exclusion above, this reads as "the layer, moved" (or
        // rotated) rather than "the layer, plus a ghost copy of it".
        if let activeTransform, let originalCanvas = transformOriginalCanvas {
            let scale = CGFloat(zoomScale)

            if activeTransform.hasDistortion {
                // Round 3 (distort): the rectangle is now an arbitrary
                // quadrilateral, which a plain CGContext translate/rotate/
                // scale (round 1/2's approach, below) can't represent — that
                // only ever produces a parallelogram, never a true
                // perspective warp. Rather than reach for Core Image or a
                // second, lighter-weight warp implementation, this reuses
                // `rasterizeTransform` itself (option (a) from the issue
                // plan): re-rasterizes `originalCanvas` through
                // `activeTransform` into a scratch full-canvas-size
                // `PixelCanvas` on every redraw and draws *that* at the
                // canvas's own `destRect` — i.e. the exact pixels
                // `commitLayerTransform()` would produce if the drag ended
                // right now, not an approximation of them. `PixelCanvas` is
                // a pixel-art-sized buffer (never larger than the document
                // itself), so redoing this per-frame while dragging is cheap
                // enough not to need caching.
                let previewCanvas = PixelCanvas(width: layerStack.width, height: layerStack.height, background: .clear)
                rasterizeTransform(activeTransform, from: originalCanvas, into: previewCanvas)
                if let warpedImage = previewCanvas.cgImage {
                    context.interpolationQuality = .none
                    context.setShouldAntialias(false)
                    // Matches `LayerStack.compositeImage()`'s own
                    // `context.setAlpha(layer.opacity)` (issue #9 review
                    // should-5): without this, a layer under 100% opacity
                    // would render fully opaque for the duration of the
                    // transform drag and only "become" translucent again the
                    // instant it's confirmed — a visible jump at commit
                    // time. Scoped with save/restore so the reduced alpha
                    // doesn't leak into the bounding-box/handle drawing
                    // right after.
                    context.saveGState()
                    context.setAlpha(CGFloat(layerStack.activeLayer.opacity))
                    context.draw(warpedImage, in: destRect)
                    context.restoreGState()
                }
            } else if let previewImage = originalCanvas.cgImage {
                // Draws the (unrotated) preview image into a rect centered on
                // the origin, inside a context translated to the rectangle's
                // view-space center and rotated by `activeTransform.rotation`
                // — rather than computing the rotated destination rect by
                // hand. `CanvasView` is already flipped (y grows downward,
                // same as `LayerTransform.corners`' own convention), so
                // `rotate(by:)` here turns the image the same direction
                // `corners` turns the rectangle. Scoped with save/restore so
                // this transform doesn't leak into the bounding-box/handle
                // drawing right after, which works in plain view-space
                // coordinates instead.
                context.saveGState()
                context.translateBy(x: activeTransform.centerX * Double(scale), y: activeTransform.centerY * Double(scale))
                context.rotate(by: activeTransform.rotation)
                let localRect = CGRect(
                    x: -activeTransform.width / 2 * Double(scale),
                    y: -activeTransform.height / 2 * Double(scale),
                    width: activeTransform.width * Double(scale),
                    height: activeTransform.height * Double(scale)
                )
                // Nearest-neighbor for the live preview too, not just the
                // final composite above — issue #9 calls this out explicitly
                // so an in-progress transform never looks blurrier than the
                // dot-exact result `commitLayerTransform()` will actually
                // produce.
                context.interpolationQuality = .none
                context.setShouldAntialias(false)
                // Matches `LayerStack.compositeImage()`'s own
                // `context.setAlpha(layer.opacity)` (issue #9 review
                // should-5) — see the `hasDistortion` branch above for why.
                // Already inside this `saveGState()`/`restoreGState()` pair,
                // so no extra scoping needed here.
                context.setAlpha(CGFloat(layerStack.activeLayer.opacity))
                context.draw(previewImage, in: localRect)
                context.restoreGState()
            }

            // Bounding box: a *solid* stroke through the (possibly rotated)
            // 4 corners directly — `activeTransform.corners` already
            // accounts for rotation (round 1 implemented that rotation math
            // even though round 1 itself never set rotation away from 0) —
            // rather than stroking an axis-aligned `CGRect`, which would be
            // wrong the moment `rotation != 0`. Solid, unlike every dashed
            // selection/rubber-band overlay elsewhere in this method, so a
            // transform-in-progress reads as visually distinct from a
            // selection.
            let (corners, edges) = CanvasView.transformHandlePoints(for: activeTransform, scale: scale)
            context.setShouldAntialias(true)
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [])
            if let topLeft = corners[.topLeft], let topRight = corners[.topRight],
               let bottomRight = corners[.bottomRight], let bottomLeft = corners[.bottomLeft] {
                context.beginPath()
                context.move(to: topLeft)
                context.addLine(to: topRight)
                context.addLine(to: bottomRight)
                context.addLine(to: bottomLeft)
                context.closePath()
                context.strokePath()
            }

            // 8 resize handles (4 corners + 4 edge midpoints): small filled
            // squares, matching `hitTestTransformHandle`'s own handle
            // positions exactly (same `transformHandlePoints` helper) so
            // what's drawn is always where a click would actually register
            // — including the rotate ring just outside each corner, which
            // draws no handle glyph of its own (matching Photoshop, where
            // the rotate hitbox is likewise invisible).
            let handleSize: CGFloat = 6
            for point in Array(corners.values) + Array(edges.values) {
                let handleRect = CGRect(
                    x: point.x - handleSize / 2,
                    y: point.y - handleSize / 2,
                    width: handleSize,
                    height: handleSize
                )
                context.setFillColor(NSColor.white.cgColor)
                context.fill(handleRect)
                context.setStrokeColor(NSColor.systemBlue.cgColor)
                context.setLineWidth(1)
                context.stroke(handleRect.insetBy(dx: 0.5, dy: 0.5))
            }
        }

        // Magnifier drag rubber-band (issue #13): a dashed selection-style
        // rectangle drawn over the already-composited canvas image. This is
        // a temporary UI overlay, not canvas pixel data, so it deliberately
        // doesn't go through the dot-perfect/no-antialiasing path above —
        // see the doc comment on `magnifierDragStart`.
        if activeTool == .magnifier, let start = magnifierDragStart, let current = magnifierDragCurrent {
            let rect = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            // Guards against the zero-size rect right after `mouseDown`,
            // before `mouseDragged` has fired even once: `start == current`
            // there, and insetting a zero-size rect by (0.5, 0.5) would
            // make its width/height negative.
            if rect.width > 0 && rect.height > 0 {
                context.setShouldAntialias(true)
                context.setStrokeColor(NSColor.selectedControlColor.cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [4, 3])
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }
        }

        // Rectangle/ellipse select drag preview (issue #11): a dashed
        // rubber-band shape drawn while the drag is in progress, separate
        // from the magnifier's own rubber-band above (different tool,
        // different state, different code path — see `selectionDragStart`'s
        // doc comment) and separate from the committed-selection outline
        // below (that one draws `selection`'s actual boundary once the drag
        // has ended; this one is just a live preview of the shape being
        // dragged out).
        if (activeTool == .rectangleSelect || activeTool == .ellipseSelect),
           let start = selectionDragStart, let current = selectionDragCurrent {
            let rect = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            if rect.width > 0 && rect.height > 0 {
                context.setShouldAntialias(true)
                context.setStrokeColor(NSColor.selectedControlColor.cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [4, 3])
                let inset = rect.insetBy(dx: 0.5, dy: 0.5)
                if activeTool == .rectangleSelect {
                    context.stroke(inset)
                } else {
                    context.strokeEllipse(in: inset)
                }
            }
        }

        // Lasso drag preview (issue #11 round 2): an open (not yet closed)
        // dashed line through every point accumulated so far, drawn through
        // pixel *centers* at the current zoom — same convention as the
        // committed-selection outline below, just not yet closed into a
        // loop since the shape isn't final until `mouseUp`.
        if activeTool == .lassoSelect, lassoVertices.count >= 2 {
            context.setShouldAntialias(true)
            context.setStrokeColor(NSColor.selectedControlColor.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            let scale = CGFloat(zoomScale)
            let points = lassoVertices.map {
                CGPoint(x: (CGFloat($0.x) + 0.5) * scale, y: (CGFloat($0.y) + 0.5) * scale)
            }
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }

        // Polygon vertex-placement preview (issue #11 round 2): an open
        // dashed line through the vertices placed so far, plus a small
        // filled marker at each one so it's clear where a click will land
        // relative to the existing vertices (in particular, the first one,
        // clicking near which closes the shape).
        if activeTool == .polygonSelect, !polygonVertices.isEmpty {
            let scale = CGFloat(zoomScale)
            let points = polygonVertices.map {
                CGPoint(x: (CGFloat($0.x) + 0.5) * scale, y: (CGFloat($0.y) + 0.5) * scale)
            }
            context.setShouldAntialias(true)
            if points.count >= 2 {
                context.setStrokeColor(NSColor.selectedControlColor.cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [4, 3])
                context.beginPath()
                context.move(to: points[0])
                for point in points.dropFirst() {
                    context.addLine(to: point)
                }
                context.strokePath()
            }
            context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(NSColor.selectedControlColor.cgColor)
            let markerRadius: CGFloat = 3
            for point in points {
                context.fillEllipse(in: CGRect(
                    x: point.x - markerRadius,
                    y: point.y - markerRadius,
                    width: markerRadius * 2,
                    height: markerRadius * 2
                ))
            }
        }

        // Committed selection outline (issue #11): a static dashed
        // "marching ants"-style border around every selected region.
        // Animation is out of scope (round 1) — this is deliberately a
        // fixed dash pattern, not a timer-driven phase offset.
        if let selection {
            context.setShouldAntialias(true)
            context.setStrokeColor(NSColor.selectedControlColor.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            let scale = CGFloat(zoomScale)
            context.beginPath()
            for (from, to) in selection.boundaryEdges() {
                context.move(to: CGPoint(x: from.x * scale, y: from.y * scale))
                context.addLine(to: CGPoint(x: to.x * scale, y: to.y * scale))
            }
            context.strokePath()
        }
    }

    // MARK: - Pencil tool (mouse-driven, 1px, no anti-aliasing)

    /// Converts a view-space point into pixel-space coordinates at the given
    /// zoom scale. Pulled out as a pure function (no `NSEvent`/window
    /// dependency) so the floor/scale math can be unit tested directly;
    /// `pixelCoordinate(for:)` is the thin `NSEvent`-driven wrapper used at
    /// runtime.
    static func pixelCoordinate(forPoint point: NSPoint, zoomScale: Int) -> (x: Int, y: Int) {
        let x = Int(floor(point.x / CGFloat(zoomScale)))
        let y = Int(floor(point.y / CGFloat(zoomScale)))
        return (x, y)
    }

    private func pixelCoordinate(for event: NSEvent) -> (x: Int, y: Int) {
        let point = convert(event.locationInWindow, from: nil)
        return CanvasView.pixelCoordinate(forPoint: point, zoomScale: zoomScale)
    }

    /// `onEditCompleted`'s history label for a pixel-painting tool (issue
    /// #19) — `nil` for every other tool, which fire `onEditCompleted` from
    /// their own dedicated gesture-completion code instead (selection
    /// confirm, transform commit).
    private static func editCompletedLabel(for tool: Tool) -> String? {
        switch tool {
        case .pencil: return "鉛筆"
        case .eraser: return "消しゴム"
        case .pen: return "ペン"
        case .eyedropper, .magnifier, .rectangleSelect, .ellipseSelect, .lassoSelect, .polygonSelect, .magicWandSelect:
            return nil
        }
    }

    /// The color a stroke paints with, derived from the active tool rather
    /// than stored on its own (issue #5): the eraser is not a special
    /// "make transparent" tool, it's simply "the pencil, but with the
    /// background color" — painting with `backgroundColor` instead of
    /// `foregroundColor`. True erasing (alpha 0) is a matter of what color
    /// the user picked, not a separate code path. The pen also paints with
    /// the foreground color, same as the pencil (issue #10) — only *how*
    /// it paints (see `paint(at:)`/`paintLine(from:to:)`) differs.
    private var paintColor: NSColor {
        activeTool == .eraser ? backgroundColor : foregroundColor
    }

    /// Paints a single point with the active tool's own method: the pencil
    /// and eraser stay on the dot-exact, no-anti-aliasing `setPixel` path
    /// (unchanged by issue #10); the pen goes through the new anti-aliased
    /// path instead.
    private func paint(at pixel: (x: Int, y: Int)) {
        switch activeTool {
        case .pencil, .eraser:
            layerStack.activeLayer.canvas.setPixel(x: pixel.x, y: pixel.y, color: paintColor, mask: selection)
        case .pen:
            layerStack.activeLayer.canvas.drawAntialiasedDot(at: pixel, color: paintColor, diameter: Self.penLineWidth, mask: selection)
        case .eyedropper:
            // The eyedropper never reaches here: `mouseDown`/`mouseDragged`
            // branch to `sampleColor(at:)` before calling `paint(at:)`
            // (issue #14). Kept only to satisfy this switch's exhaustiveness.
            return
        case .magnifier:
            // The magnifier never reaches here either: `mouseDown`/
            // `mouseDragged`/`mouseUp` branch to the zoom/drag handling
            // before calling `paint(at:)` (issue #13). Kept only to satisfy
            // this switch's exhaustiveness.
            return
        case .rectangleSelect, .ellipseSelect, .lassoSelect, .polygonSelect, .magicWandSelect:
            // Same as the magnifier above: these branch to their own
            // drag/combine handling in `mouseDown`/`mouseDragged`/`mouseUp`
            // before calling `paint(at:)` (issue #11). Kept only to satisfy
            // this switch's exhaustiveness.
            return
        }
    }

    /// Paints a stroke between two points with the active tool's own
    /// method, mirroring `paint(at:)`'s tool switch.
    private func paintLine(from p0: (x: Int, y: Int), to p1: (x: Int, y: Int)) {
        switch activeTool {
        case .pencil, .eraser:
            layerStack.activeLayer.canvas.drawLine(from: p0, to: p1, color: paintColor, mask: selection)
        case .pen:
            layerStack.activeLayer.canvas.drawAntialiasedLine(from: p0, to: p1, color: paintColor, lineWidth: Self.penLineWidth, mask: selection)
        case .eyedropper:
            // Same as `paint(at:)` above: the eyedropper never drags into a
            // stroke (issue #14), this exists only for exhaustiveness.
            return
        case .magnifier:
            // Same as `paint(at:)` above: the magnifier never drags into a
            // stroke (issue #13), this exists only for exhaustiveness.
            return
        case .rectangleSelect, .ellipseSelect, .lassoSelect, .polygonSelect, .magicWandSelect:
            // Same as `paint(at:)` above: these never drag into a stroke
            // (issue #11), this exists only for exhaustiveness.
            return
        }
    }

    /// Reads the color at a pixel out of the currently displayed
    /// composite — what the user actually sees, not just the active
    /// layer's own contents — so the eyedropper picks up whatever color is
    /// visible on screen, including layers stacked above/below the active
    /// one (issue #14). Returns `nil` for a pixel outside the canvas.
    ///
    /// Because this reads back from `layerStack.compositeImage()` (an sRGB
    /// `CGContext`) rather than the active layer's own bitmap, the returned
    /// color is not guaranteed to be byte-identical to whatever `setPixel`
    /// originally wrote — a real color-space conversion through the
    /// composite is not a no-op for saturated primaries (see
    /// `CanvasViewTests.byteRGB(of:)`'s doc comment, which measured ~38/255
    /// of drift on the green channel for pure red).
    private func sampleColor(at pixel: (x: Int, y: Int)) -> NSColor? {
        guard pixel.x >= 0, pixel.x < layerStack.width, pixel.y >= 0, pixel.y < layerStack.height else { return nil }
        guard let image = layerStack.compositeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.colorAt(x: pixel.x, y: pixel.y)
    }

    /// Reads Shift/Option out of `flags` into a `SelectionCombineMode`
    /// (issue #11), matching Photoshop's modifier-key conventions — see
    /// `SelectionCombineMode`'s own doc comment. Shared by every selection
    /// tool's `mouseDown` (rectangle/ellipse drag, lasso drag, polygon's
    /// first click) so this mapping lives in exactly one place instead of
    /// being re-derived per tool (round 2 pulled this out of the
    /// rectangle/ellipse branch below, which had it inline under round 1).
    private static func combineMode(for flags: NSEvent.ModifierFlags) -> SelectionCombineMode {
        if flags.contains(.shift) && flags.contains(.option) {
            return .intersect
        } else if flags.contains(.shift) {
            return .add
        } else if flags.contains(.option) {
            return .subtract
        } else {
            return .replace
        }
    }

    /// Combines `newMask` into the current `selection` per `mode`
    /// (`.replace` when `nil`), then normalizes an empty result back to
    /// `nil` — shared by every selection tool's finalize step (rectangle/
    /// ellipse `mouseUp`, lasso `mouseUp`, polygon close) so the union/
    /// subtract/intersect/replace-then-collapse-to-nil rule lives in exactly
    /// one place. See `SelectionCombineMode`'s doc comment for the
    /// Shift/Option semantics, and the original round-1 `mouseUp` comment
    /// (now here) for why `nil` is treated as an *empty* base mask (not
    /// "everything selected") and why an empty combined result collapses
    /// back to `nil` (an all-false mask would block all editing everywhere —
    /// worse than no selection at all).
    private func applyCombinedSelection(_ newMask: SelectionMask, mode: SelectionCombineMode?) {
        let base = selection ?? SelectionMask(width: layerStack.width, height: layerStack.height)
        let combined: SelectionMask
        switch mode ?? .replace {
        case .replace:
            combined = newMask
        case .add:
            combined = base.unioned(with: newMask)
        case .subtract:
            combined = base.subtracting(newMask)
        case .intersect:
            combined = base.intersected(with: newMask)
        }
        selection = combined.isEmpty ? nil : combined
    }

    /// Closes the in-progress polygon selection (issue #11 round 2): builds
    /// a mask from `polygonVertices` via `SelectionMask.polygon(...)`,
    /// combines it into `selection` with `polygonCombineMode`, and clears
    /// all polygon gesture state either way. Called both from `mouseDown`
    /// (click near the first vertex) and `keyDown` (Return).
    private func closePolygon() {
        defer {
            polygonVertices = []
            polygonFirstPoint = nil
            polygonCombineMode = nil
            needsDisplay = true
        }
        guard polygonVertices.count >= 3 else { return }
        let newMask = SelectionMask.polygon(vertices: polygonVertices, width: layerStack.width, height: layerStack.height)
        applyCombinedSelection(newMask, mode: polygonCombineMode)
        onEditCompleted?("選択範囲")
    }

    override func keyDown(with event: NSEvent) {
        // Layer transform mode (issue #9) takes priority over every other
        // key handling below, the same way it preempts `mouseDown`/
        // `mouseDragged`/`mouseUp` — see `activeTransform`'s doc comment.
        // Same keyCode/Return convention as the polygon tool's own
        // Escape/Return handling further down (36/76 for Return/keypad
        // Enter, 53 for Escape).
        if activeTransform != nil {
            switch event.keyCode {
            case 36, 76:
                commitLayerTransform()
            case 53:
                cancelLayerTransform()
            default:
                super.keyDown(with: event)
            }
            return
        }
        // Only the polygon tool, and only mid-gesture, cares about Escape/
        // Return (issue #11 round 2) — every other key, and every other
        // tool, falls through to `super` unchanged.
        guard activeTool == .polygonSelect, !polygonVertices.isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: // Escape: cancel the in-progress polygon, no selection change.
            polygonVertices = []
            polygonFirstPoint = nil
            polygonCombineMode = nil
            needsDisplay = true
        case 36, 76: // Return / keypad Enter: close with the vertices placed so far.
            closePolygon()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Reclaims first responder on every click (issue #11 round 2):
        // `CanvasView` overrides `mouseDown(with:)` without calling `super`,
        // so it doesn't get AppKit's normal "clicking a view makes it first
        // responder" behavior for free. Without this, once some other
        // control (e.g. the zoom text field) had taken first responder,
        // clicking back on the canvas wouldn't restore it, and the polygon
        // select tool's Escape/Return shortcuts in `keyDown(with:)` would
        // silently stop working after the first such detour.
        window?.makeFirstResponder(self)
        // Reset at the start of every new gesture (issue #19) — see
        // `paintedDuringGesture`'s own doc comment.
        paintedDuringGesture = false
        // Layer transform mode (issue #9) preempts every `activeTool`
        // branch below — see `activeTransform`'s doc comment. A double-click
        // inside the rectangle's interior (not on a handle) confirms the
        // transform outright (a common image-editor convention for "done
        // adjusting, apply it now"); any other click on the rectangle or a
        // handle just starts that drag, resolved in `mouseDragged`/
        // `mouseUp` below.
        if let activeTransform {
            let point = convert(event.locationInWindow, from: nil)
            var handle = hitTestTransformHandle(at: point, transform: activeTransform)
            // Option+corner is the free-transform / distort gesture (round
            // 3), Photoshop's own convention — every other handle (move,
            // edge, rotate) is unaffected by Option and keeps its round 1/2
            // meaning.
            if case .some(.corner(let corner)) = handle, event.modifierFlags.contains(.option) {
                handle = .distort(corner)
            }
            if event.clickCount == 2, handle == .move {
                commitLayerTransform()
                return
            }
            transformDragHandle = handle
            transformDragStartPoint = point
            transformDragStartTransform = activeTransform
            return
        }
        // Unconditionally clear any leftover magnifier drag state at the
        // start of every new mouse-down session (issue #13 hardening): the
        // current mouse-event dispatch model can't actually switch
        // `activeTool` mid-drag, but a future keyboard-shortcut tool switch
        // could, and without this reset a stale rubber-band rectangle could
        // flash on screen the next time the magnifier is reselected.
        magnifierDragStart = nil
        magnifierDragCurrent = nil
        let pixel = pixelCoordinate(for: event)
        if activeTool == .eyedropper {
            if let pixelColor = sampleColor(at: pixel) {
                let isSecondary = event.modifierFlags.contains(.option)
                onColorPicked?(pixelColor, isSecondary)
            }
            return
        }
        if activeTool == .magnifier {
            // Just records the drag's start point (issue #13); the actual
            // zoom happens in `mouseUp(with:)` once the gesture — click or
            // drag — is known. Skips the pixel-painting path entirely, same
            // as the eyedropper branch above.
            let point = convert(event.locationInWindow, from: nil)
            magnifierDragStart = point
            magnifierDragCurrent = point
            return
        }
        if activeTool == .rectangleSelect || activeTool == .ellipseSelect {
            // Records the drag's start point and the modifier-derived
            // combine mode (issue #11); the actual mask is built once the
            // drag ends, in `mouseUp(with:)`. Skips the pixel-painting path
            // entirely, same as the eyedropper/magnifier branches above.
            let point = convert(event.locationInWindow, from: nil)
            selectionDragStart = point
            selectionDragCurrent = point
            selectionCombineMode = CanvasView.combineMode(for: event.modifierFlags)
            return
        }
        if activeTool == .lassoSelect {
            // Starts a fresh free-form path (issue #11 round 2); the mask
            // isn't built until the drag ends, in `mouseUp(with:)`. Skips
            // the pixel-painting path entirely, same as the other selection
            // tools above.
            lassoVertices = [pixel]
            lassoCombineMode = CanvasView.combineMode(for: event.modifierFlags)
            needsDisplay = true
            return
        }
        if activeTool == .polygonSelect {
            // A click-based state machine, independent of the lasso's
            // drag-based one (issue #11 round 2 — see `Tool.polygonSelect`'s
            // doc comment): each click either closes the shape (clicking
            // near the first vertex, once there are at least 3) or appends
            // a new vertex. Skips the pixel-painting path entirely, same as
            // every other selection tool above.
            let point = convert(event.locationInWindow, from: nil)
            if let firstPoint = polygonFirstPoint, polygonVertices.count >= 3,
               hypot(point.x - firstPoint.x, point.y - firstPoint.y) <= Self.polygonCloseDistance {
                closePolygon()
                return
            }
            if polygonVertices.isEmpty {
                polygonFirstPoint = point
                polygonCombineMode = CanvasView.combineMode(for: event.modifierFlags)
            }
            polygonVertices.append(pixel)
            needsDisplay = true
            return
        }
        if activeTool == .magicWandSelect {
            // A single click is the whole gesture (issue #11 round 3 — see
            // `Tool.magicWandSelect`'s doc comment), so unlike the other four
            // selection tools this needs no `mouseDragged`/`mouseUp`
            // handling of its own: the mask is built and applied right here.
            //
            // Sampled from `layerStack.activeLayer.canvas` (the active
            // layer's own pixels), not `sampleColor(at:)`'s composited
            // result the eyedropper (issue #14) reads from: the eyedropper
            // is about picking up whatever color the user visually sees, but
            // the magic wand is an edit-target-specific operation — "select
            // this region of *this layer*" — so it has to look at the same
            // pixels `paint(at:)` would actually modify, not a flattened
            // view that could span other layers stacked above/below.
            let canvas = layerStack.activeLayer.canvas
            let newMask = SelectionMask.magicWand(
                startX: pixel.x, startY: pixel.y,
                colorAt: { x, y in canvas.rawPixel(x: x, y: y) },
                tolerance: magicWandTolerance,
                width: layerStack.width, height: layerStack.height
            )
            let mode = CanvasView.combineMode(for: event.modifierFlags)
            applyCombinedSelection(newMask, mode: mode)
            needsDisplay = true
            // The magic wand's whole gesture is this one click (issue #19,
            // matching #11's own "no drag/mouseUp handling" doc comment on
            // `Tool.magicWandSelect`), so its `onEditCompleted` fires right
            // here rather than in `mouseUp`.
            onEditCompleted?("選択範囲")
            return
        }
        paint(at: pixel)
        paintedDuringGesture = true
        lastPixel = pixel
        needsDisplay = true
        onLayerContentChanged?()
    }

    override func mouseDragged(with event: NSEvent) {
        // Layer transform mode (issue #9) preempts every `activeTool` branch
        // below — see `activeTransform`'s doc comment.
        if let startTransform = transformDragStartTransform, let handle = transformDragHandle, let startPoint = transformDragStartPoint {
            let point = convert(event.locationInWindow, from: nil)
            let scale = CGFloat(zoomScale)
            let dx = Double((point.x - startPoint.x) / scale)
            let dy = Double((point.y - startPoint.y) / scale)
            switch handle {
            case .move:
                var transform = startTransform
                transform.centerX = startTransform.centerX + dx
                transform.centerY = startTransform.centerY + dy
                activeTransform = transform
            case .corner(let corner):
                // `resizeByCorner`'s anchor math always reads the plain
                // UNDISTORTED rectangle's own local-frame corner position,
                // never the anchor corner's own `distort*` offset (issue #9
                // review should-3) — so once any corner has been distorted,
                // an ordinary (non-Option) corner resize is not guaranteed
                // to preserve the existing distortion correctly. Rather than
                // risk a silently-wrong shape, this simply disables plain
                // resize entirely while `hasDistortion` is true: dragging a
                // corner/edge handle here is a no-op (see the corresponding
                // `.edge` case below) until the transform is committed/
                // cancelled and a fresh, undistorted one is started. Option+
                // corner (`.distort` below) is unaffected — that's still how
                // you adjust an already-distorted transform further.
                if !startTransform.hasDistortion {
                    activeTransform = CanvasView.resizeByCorner(corner, start: startTransform, dx: dx, dy: dy, keepAspect: event.modifierFlags.contains(.shift))
                }
            case .edge(let edge):
                // Same reasoning as `.corner` above.
                if !startTransform.hasDistortion {
                    activeTransform = CanvasView.resizeByEdge(edge, start: startTransform, dx: dx, dy: dy)
                }
            case .rotate:
                // Angle of the mouse relative to the rectangle's own center,
                // in view space (canvas pixel space scaled by `zoomScale` —
                // no extra flip needed since `CanvasView` is already
                // flipped, so this uses the same y-grows-downward
                // convention `LayerTransform.corners`' rotation math does).
                // Like the resize handles above, this recomputes from
                // `startTransform`'s own rotation plus the *total* angle
                // moved since the drag began, rather than accumulating a
                // delta every `mouseDragged` call, to avoid drift.
                let centerXView = startTransform.centerX * Double(scale)
                let centerYView = startTransform.centerY * Double(scale)
                let startAngle = atan2(Double(startPoint.y) - centerYView, Double(startPoint.x) - centerXView)
                let currentAngle = atan2(Double(point.y) - centerYView, Double(point.x) - centerXView)
                var newRotation = startTransform.rotation + (currentAngle - startAngle)
                if event.modifierFlags.contains(.shift) {
                    // Snaps to 15-degree increments (Photoshop's own
                    // rotate-handle convention under Shift).
                    let degrees = newRotation * 180 / .pi
                    let snappedDegrees = (degrees / 15).rounded() * 15
                    newRotation = snappedDegrees * .pi / 180
                }
                var transform = startTransform
                transform.rotation = newRotation
                activeTransform = transform
            case .distort(let corner):
                // Updates only the dragged corner's own offset, by the total
                // screen/canvas-axis movement since the drag began (same
                // "recompute from `startTransform` plus total movement, not
                // an incremental per-event delta" convention as every other
                // handle above) — every other corner, the center, the size,
                // and the rotation are all left exactly as `startTransform`
                // had them. No rotation correction here (unlike
                // `resizeByCorner`/`resizeByEdge`): a distort drag moves the
                // corner freely in screen space rather than along the
                // rectangle's local axes, per issue #9's round-3 plan.
                var transform = startTransform
                let moved = CGVector(dx: dx, dy: dy)
                switch corner {
                case .topLeft:
                    transform.distortTopLeft = CGVector(dx: startTransform.distortTopLeft.dx + moved.dx, dy: startTransform.distortTopLeft.dy + moved.dy)
                case .topRight:
                    transform.distortTopRight = CGVector(dx: startTransform.distortTopRight.dx + moved.dx, dy: startTransform.distortTopRight.dy + moved.dy)
                case .bottomRight:
                    transform.distortBottomRight = CGVector(dx: startTransform.distortBottomRight.dx + moved.dx, dy: startTransform.distortBottomRight.dy + moved.dy)
                case .bottomLeft:
                    transform.distortBottomLeft = CGVector(dx: startTransform.distortBottomLeft.dx + moved.dx, dy: startTransform.distortBottomLeft.dy + moved.dy)
                }
                activeTransform = transform
            }
            needsDisplay = true
            return
        }
        if activeTransform != nil {
            // The drag started outside the rectangle entirely (`mouseDown`'s
            // hit test returned `nil`) — deliberately inert, but still
            // consumes the event rather than falling through to whatever
            // `activeTool` happens to be set to underneath transform mode.
            return
        }
        if activeTool == .eyedropper {
            // Click-only sampling (issue #14): continuous sampling while
            // dragging is out of scope for this issue.
            return
        }
        if activeTool == .magnifier {
            magnifierDragCurrent = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            return
        }
        if activeTool == .rectangleSelect || activeTool == .ellipseSelect {
            selectionDragCurrent = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            return
        }
        if activeTool == .lassoSelect {
            let pixel = pixelCoordinate(for: event)
            // Thins out consecutive duplicate points (e.g. the pointer
            // hasn't crossed into a new pixel since the last event) rather
            // than growing the path on every single mouse-moved callback —
            // enough de-duplication to keep the vertex list from ballooning
            // on a slow drag without needing a real distance-based
            // simplification algorithm.
            if lassoVertices.last.map({ $0 != pixel }) ?? true {
                lassoVertices.append(pixel)
            }
            needsDisplay = true
            return
        }
        let pixel = pixelCoordinate(for: event)
        if let last = lastPixel {
            paintLine(from: last, to: pixel)
        } else {
            paint(at: pixel)
        }
        paintedDuringGesture = true
        lastPixel = pixel
        needsDisplay = true
        onLayerContentChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        // Layer transform mode (issue #9) preempts every `activeTool` branch
        // below — see `activeTransform`'s doc comment. `mouseUp` never
        // confirms the transform itself (only Return / double-click do,
        // per `keyDown`/`mouseDown` above) — it just resets the drag state
        // so the next `mouseDown` starts a fresh hit test.
        if activeTransform != nil {
            transformDragHandle = nil
            transformDragStartPoint = nil
            transformDragStartTransform = nil
            return
        }
        if activeTool == .rectangleSelect || activeTool == .ellipseSelect {
            defer {
                selectionDragStart = nil
                selectionDragCurrent = nil
                selectionCombineMode = nil
                needsDisplay = true
            }
            guard let start = selectionDragStart, let current = selectionDragCurrent else { return }

            let p0 = CanvasView.pixelCoordinate(forPoint: start, zoomScale: zoomScale)
            let p1 = CanvasView.pixelCoordinate(forPoint: current, zoomScale: zoomScale)

            let newMask: SelectionMask
            if activeTool == .rectangleSelect {
                newMask = SelectionMask.rectangle(x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y, width: layerStack.width, height: layerStack.height)
            } else {
                // The dragged rectangle's two pixel corners bound the
                // ellipse: pixel index `x` occupies the continuous range
                // `[x, x + 1)`, so the bounding box's continuous extent runs
                // from `min(x0, x1)` to `max(x0, x1) + 1` (and likewise for
                // y) — that's where `+ 1` below comes from, not an
                // off-by-one.
                let minX = min(p0.x, p1.x)
                let maxX = max(p0.x, p1.x)
                let minY = min(p0.y, p1.y)
                let maxY = max(p0.y, p1.y)
                let centerX = Double(minX + maxX + 1) / 2
                let centerY = Double(minY + maxY + 1) / 2
                let radiusX = Double(maxX - minX + 1) / 2
                let radiusY = Double(maxY - minY + 1) / 2
                newMask = SelectionMask.ellipse(centerX: centerX, centerY: centerY, radiusX: radiusX, radiusY: radiusY, width: layerStack.width, height: layerStack.height)
            }

            // For combine math (union/subtract/intersect), a `nil` existing
            // selection is treated as an *empty* mask — not "everything
            // selected" — so Shift/Option-dragging from a clean,
            // no-selection state behaves the way users actually expect:
            // Shift-drag (`.add`) starts a brand-new selection exactly as a
            // plain drag would; Option-drag (`.subtract`) / Shift+Option-drag
            // (`.intersect`) are no-ops, since there's nothing yet to
            // subtract from or intersect with. This is a *different* rule
            // from `AppDelegate`'s "選択範囲を反転" command, which
            // deliberately treats `nil` as "everything selected" for that
            // command's own semantics (see its doc comment) — the two
            // operations don't share one universal "what does nil mean"
            // rule, they're each documented independently. An empty combined
            // result collapses back to `nil` rather than staying a real,
            // all-`false` mask (issue #11, decision made ahead of
            // implementation) — see `applyCombinedSelection`'s doc comment.
            applyCombinedSelection(newMask, mode: selectionCombineMode)
            onEditCompleted?("選択範囲")
            return
        }
        if activeTool == .lassoSelect {
            defer {
                lassoVertices = []
                lassoCombineMode = nil
                needsDisplay = true
            }
            // Fewer than 3 points can't enclose an area — rather than build
            // a mask that `SelectionMask.polygon(...)` would return empty
            // anyway (and then have `applyCombinedSelection` potentially
            // wipe an existing `.replace`-mode selection for what was really
            // just a stray click), an incomplete lasso path is simply
            // discarded without touching `selection` at all.
            guard lassoVertices.count >= 3 else { return }
            let newMask = SelectionMask.polygon(vertices: lassoVertices, width: layerStack.width, height: layerStack.height)
            applyCombinedSelection(newMask, mode: lassoCombineMode)
            onEditCompleted?("選択範囲")
            return
        }
        guard activeTool == .magnifier else {
            // Pencil/eraser/pen strokes fire `onEditCompleted` here, at the
            // gesture's actual end, and only if something was actually
            // painted during it (issue #19) — a click that landed on the
            // eyedropper/polygon-select/magic-wand tools also reaches this
            // fallback (they handle their own gesture end elsewhere or take
            // no `mouseUp` action at all), but `editCompletedLabel` returns
            // `nil` for those, so nothing fires.
            if paintedDuringGesture, let label = CanvasView.editCompletedLabel(for: activeTool) {
                onEditCompleted?(label)
            }
            paintedDuringGesture = false
            lastPixel = nil
            return
        }
        defer {
            magnifierDragStart = nil
            magnifierDragCurrent = nil
            needsDisplay = true
        }
        guard let start = magnifierDragStart, let current = magnifierDragCurrent else { return }

        let distance = hypot(current.x - start.x, current.y - start.y)
        if distance < Self.magnifierClickThreshold {
            // A plain click (issue #13): Option-click zooms out one step,
            // a plain click zooms in one step — both simple single-step
            // zooms via the existing `zoomIn()`/`zoomOut()`. The clicked
            // pixel must be read at the *pre*-zoom scale — `zoomIn()`/
            // `zoomOut()` overwrite `zoomScale` — since `current` is a
            // view-space point captured while the canvas was still
            // displayed at the old zoom.
            let pixel = CanvasView.pixelCoordinate(forPoint: current, zoomScale: zoomScale)
            if event.modifierFlags.contains(.option) {
                zoomOut()
            } else {
                zoomIn()
            }
            centerScroll(onPixelPoint: pixel)
            return
        }

        // A rectangle drag (issue #13): zoom to whichever supported level
        // fits the dragged rectangle as large as possible inside the
        // viewport, then scroll so the rectangle's center lands in the
        // middle of the viewport.
        let rectStart = CanvasView.pixelCoordinate(forPoint: start, zoomScale: zoomScale)
        let rectEnd = CanvasView.pixelCoordinate(forPoint: current, zoomScale: zoomScale)
        let pixelWidth = abs(rectEnd.x - rectStart.x)
        let pixelHeight = abs(rectEnd.y - rectStart.y)
        let viewportSize = enclosingScrollView?.contentView.bounds.size ?? bounds.size
        let bestLevel = CanvasView.bestFitZoomLevel(
            forPixelSize: (width: max(pixelWidth, 1), height: max(pixelHeight, 1)),
            viewportSize: viewportSize,
            levels: CanvasView.zoomLevels
        )
        setZoomScale(bestLevel)

        let centerPixel = (
            x: (min(rectStart.x, rectEnd.x) + max(rectStart.x, rectEnd.x)) / 2,
            y: (min(rectStart.y, rectEnd.y) + max(rectStart.y, rectEnd.y)) / 2
        )
        centerScroll(onPixelPoint: centerPixel)
    }

    /// Scrolls the enclosing scroll view so that `pixel` (in canvas
    /// pixel-space) lands in the middle of the viewport, at the current
    /// `zoomScale` (issue #13). `CanvasView` is expected to sit inside an
    /// `NSScrollView` at runtime (see `AppDelegate.makeRootView()`); when
    /// there isn't one — e.g. an off-screen view built directly in a test —
    /// this is a no-op rather than a crash.
    private func centerScroll(onPixelPoint pixel: (x: Int, y: Int)) {
        guard let scrollView = enclosingScrollView else { return }
        let pointInView = NSPoint(
            x: (CGFloat(pixel.x) + 0.5) * CGFloat(zoomScale),
            y: (CGFloat(pixel.y) + 0.5) * CGFloat(zoomScale)
        )
        let viewportSize = scrollView.contentView.bounds.size
        let origin = NSPoint(
            x: pointInView.x - viewportSize.width / 2,
            y: pointInView.y - viewportSize.height / 2
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
