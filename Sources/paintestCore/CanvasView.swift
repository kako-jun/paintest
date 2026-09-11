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
    /// The pen tool's own brush settings (issue #20) — size/hardness/
    /// opacity/flow. Kept directly on `CanvasView` with no separate
    /// `AppDelegate` copy, the same "one tool's own adjustable numeric
    /// setting" pattern `magicWandTolerance` below already uses (unlike
    /// `foregroundColor`/`backgroundColor` above, which several other views
    /// also need to mirror). `AppDelegate.updateOptionBar(for:)`'s `.pen`
    /// case reads/writes this directly through `OptionBarView`'s sliders.
    var penBrushSettings = PenBrushSettings()
    /// The text tool's own font/size/writing-direction settings (issue
    /// #42) — same "one tool's own adjustable setting, no separate
    /// `AppDelegate` copy" pattern as `penBrushSettings` above.
    /// `AppDelegate.updateOptionBar(for:)`'s `.text` case reads/writes this
    /// directly through `OptionBarView`'s controls.
    var textSettings = TextToolSettings()
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
    /// nothing. `AppDelegate` forwards `label` (plus the current selection)
    /// into `HistoryManager.record(_:selection:label:)`.
    var onEditCompleted: ((String) -> Void)?

    /// Fired only when `CanvasView` itself swaps in a brand-new `LayerStack`
    /// *instance* (issue #21: `commitCrop()`, the only call site so far) —
    /// as opposed to `onEditCompleted`, which fires for every completed edit
    /// including ones that just mutate the existing `layerStack`/its layers
    /// in place. That distinction matters here because `Document.layerStack`
    /// and `LayerPanelView` each hold their own separate reference to the
    /// pre-crop stack: every other edit in this file (pencil strokes, layer
    /// transforms, pen strokes) only ever writes into a `Layer.canvas` that
    /// reference already points at, so those two stay implicitly in sync for
    /// free. `LayerStack.width`/`height` are `let`, so a crop can only ever
    /// produce a whole new instance — this callback is what tells
    /// `AppDelegate` to re-point `Document.layerStack`/`LayerPanelView` at it,
    /// mirroring what `activateActiveDocument()`/`applyHistorySnapshot(_:)`
    /// already do whenever the displayed document's own `layerStack`
    /// reference changes.
    var onLayerStackReplaced: ((LayerStack) -> Void)?

    /// The active selection, if any — `nil` means "no restriction", i.e. the
    /// whole canvas is editable (issue #11). `AppDelegate` keeps this in
    /// sync with `Document.selection` the same way it does `zoomScale`.
    var selection: SelectionMask? { didSet { needsDisplay = true } }

    static let zoomLevels = [1, 2, 4, 8, 16, 32]
    static let defaultZoomScale = 4
    private var lastPixel: (x: Int, y: Int)?
    /// The in-progress pen stroke's accumulation buffer (issue #20) — a
    /// same-size, transparent scratch `PixelCanvas` that `stampPenDab(at:)`/
    /// `stampPenDabs(from:to:)` stamp dabs onto (each at `penBrushSettings
    /// .flow` alpha) for the duration of one pen `mouseDown`/`mouseDragged`
    /// gesture. `nil` outside of an active pen stroke — created fresh in
    /// `mouseDown`'s `.pen` branch, stamped into across `mouseDragged`, and
    /// merged into the real active layer (then discarded) by
    /// `flushPenStroke()` at `mouseUp`. See that method's doc comment for
    /// why "buffer, then one final composite" — rather than stamping dabs
    /// straight into the layer the way `paint(at:)` does for pencil/eraser
    /// — is what makes `penBrushSettings.opacity` behave as a whole-stroke
    /// cap instead of a per-dab one.
    private var penStrokeBuffer: PixelCanvas?
    /// Whether `paint(at:)`/`paintLine(from:to:)` was actually invoked
    /// during the current pencil/eraser/pen gesture (issue #19) — set in
    /// `mouseDown`/`mouseDragged`'s pixel-painting fallback path (the only
    /// place those two methods are called for a content-editing tool; see
    /// `paint(at:)`'s own doc comment for why every other tool's branch
    /// returns before reaching it) and consumed once in `mouseUp` to decide
    /// whether to fire `onEditCompleted`. Reset at the start of every new
    /// `mouseDown` gesture.
    private var paintedDuringGesture = false

    /// The text tool's in-progress overlay editor (issue #42) — a real
    /// `NSTextView` subclass placed as a direct subview of `CanvasView`,
    /// positioned over the clicked canvas pixel, `nil` outside of an
    /// active text-edit gesture. Unlike the pen's `penStrokeBuffer` (an
    /// offscreen scratch `PixelCanvas`), this is a live, visible AppKit
    /// control the user types directly into — added as a subview here
    /// (rather than a separate window/panel) so it scrolls/zooms along
    /// with `CanvasView` for free.
    private var textEditor: TextToolEditorView?
    /// The canvas-pixel coordinate the text tool was clicked at (issue
    /// #42) — where `commitTextEdit()`/`rasterizeText(_:at:)` anchor the
    /// rasterized text's top-left corner. `nil` exactly when `textEditor`
    /// is (the two are always set/cleared together).
    private var textInsertionPixel: (x: Int, y: Int)?

    private static let textEditorMinWidth: CGFloat = 40
    private static let textEditorMinHeight: CGFloat = 24
    /// A generous cap on the overlay editor's own auto-growing size (issue
    /// #42), in view points — large enough for a normal sentence or two at
    /// typical zoom levels without letting a runaway paste balloon the
    /// overlay past the window.
    private static let textEditorMaxSize: CGFloat = 600

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

    /// The bucket fill tool's own color-similarity cutoff (issue #38), kept
    /// independent of `magicWandTolerance` above even though both feed the
    /// same `SelectionMask.magicWand(...)` — a user might want a looser
    /// tolerance for "flood-fill this messy scan's background" than for
    /// "select this flat-colored shape precisely", so sharing one property
    /// between the two tools would make adjusting one silently affect the
    /// other. Same `32` starting default as `magicWandTolerance`, same
    /// "`AppDelegate` keeps `OptionBarView`'s slider in sync" wiring.
    var bucketFillTolerance: Int = 32

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

    /// Whether a pen stroke's accumulation buffer is currently live (issue
    /// #20) — `true` exactly when `penStrokeBuffer` is non-`nil`. Exposed
    /// read-only, mirroring `isTransforming` immediately above for exactly
    /// the same reason: `penStrokeBuffer` is a *pending* edit against
    /// `layerStack.activeLayer.canvas` that doesn't land for real until
    /// `flushPenStroke()` runs (at `mouseUp`), so anything that can swap out
    /// `layerStack`, change `activeLayerIndex`, or restore a whole different
    /// history snapshot out from under it needs to flush or cancel it first
    /// — see `AppDelegate`'s `activateActiveDocument()`, `layerPanelView
    /// .willChangeActiveLayer`, `undo()`/`redo()`, `historyPanelView
    /// .onJumpToIndex`, and `commitAnyPendingLayerEdits()`, each of which
    /// already does the equivalent for `isTransforming`.
    var isPenStrokeInProgress: Bool { penStrokeBuffer != nil }

    /// Whether a crop rectangle is currently pending (issue #21 test-design
    /// review) — `true` exactly when `cropRect` is non-`nil`. Exposed
    /// read-only, mirroring `isTransforming`/`isPenStrokeInProgress` above,
    /// for a related but distinct hazard: `cropRect` holds pixel coordinates
    /// against *this* `layerStack`'s own size, so anything that can swap
    /// `layerStack` out for a different (possibly differently-sized) one, or
    /// restore a whole different history snapshot, needs to discard it
    /// first — unlike `isTransforming`/`isPenStrokeInProgress`, whose callers
    /// commit/flush the pending edit onto the canvas, every one of these
    /// callers instead calls `cancelCrop()`: `commitCrop()` is a destructive,
    /// canvas-resizing operation, and auto-committing it the instant the user
    /// switches documents/undoes/redoes/jumps history would be surprising and
    /// unrecoverable in a way flushing a pen stroke or baking in a transform
    /// isn't. See `AppDelegate.activateActiveDocument()`, `undo()`/`redo()`,
    /// `historyPanelView.onJumpToIndex`, and `layerPanelView
    /// .willChangeActiveLayer`, each of which already does the equivalent for
    /// `isTransforming`/`isPenStrokeInProgress`.
    var isCropping: Bool { cropRect != nil }

    /// Whether the text tool's overlay editor is currently live (issue #42)
    /// — `true` exactly when `textEditor` is non-`nil`. Exposed read-only,
    /// mirroring `isPenStrokeInProgress` above for the identical reason and
    /// with the identical commit-not-cancel treatment: the overlay's typed
    /// text is a *pending* edit against `layerStack.activeLayer.canvas` that
    /// doesn't land for real until `commitTextEdit()` runs, so anything that
    /// can swap out `layerStack`, change `activeLayerIndex`, or restore a
    /// whole different history snapshot out from under it needs to commit or
    /// cancel it first — see `AppDelegate`'s `activateActiveDocument()`,
    /// `layerPanelView.willChangeActiveLayer`, `undo()`/`redo()`,
    /// `historyPanelView.onJumpToIndex`, and `commitAnyPendingLayerEdits()`,
    /// each of which already does the equivalent for `isPenStrokeInProgress`.
    var isTextEditing: Bool { textEditor != nil }

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
            // A stale pending crop rectangle (issue #21) must not survive a
            // tool switch either — same reasoning as the selection tools'
            // resets just above: nothing has been applied to any pixels yet
            // (only `commitCrop()` does that), so there's nothing to
            // preserve by leaving it around once the crop tool itself is no
            // longer selected.
            cancelCrop()
            // A stale in-progress pen stroke (issue #20) must not survive a
            // tool switch, or it would otherwise sit around and get silently
            // flushed onto the layer by some later, unrelated `mouseUp` once
            // the user switches back to `.pen`. Switching tools never
            // changes `layerStack.activeLayer`, though, so the same safety
            // reasoning as `mouseDown`'s `.pen` branch (issue #20 review)
            // applies here too: flush (don't discard) so the pixels already
            // drawn in this stroke aren't silently lost.
            if isPenStrokeInProgress {
                flushPenStroke()
            }
            // A stale in-progress text edit (issue #42) must not survive a
            // tool switch either, same "flush, don't discard" rule as the
            // pen stroke just above — `commitTextEdit()` bakes whatever was
            // already typed into the active layer rather than silently
            // dropping it. Losing focus when another tool's button is
            // clicked usually triggers this already via
            // `textDidEndEditing(_:)` below, but that relies on AppKit
            // actually reassigning first responder away from the editor,
            // which isn't guaranteed for every path that can change
            // `activeTool` (e.g. a future keyboard-shortcut tool switch) —
            // this is the same defensive belt-and-suspenders reasoning the
            // pen's own `isPenStrokeInProgress` check follows.
            if isTextEditing {
                commitTextEdit()
            }
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
        // Deliberately does *not* auto-commit/cancel `isTextEditing` here
        // (issue #42), unlike `activeTool`'s own `didSet` — this is a shared
        // low-level primitive called from several different `AppDelegate`
        // call sites that each want different treatment for a pending text
        // edit (`activateActiveDocument()`/`layerPanelView
        // .willChangeActiveLayer` commit it, the same as
        // `isPenStrokeInProgress`; `undo()`/`redo()`/`historyPanelView
        // .onJumpToIndex` cancel it instead, since it was never itself
        // recorded as a history entry) — see `isTextEditing`'s own doc
        // comment. Each of those callers is responsible for calling
        // `commitTextEdit()`/`cancelTextEdit()` *before* it calls this
        // method, mirroring exactly how they already handle
        // `isPenStrokeInProgress`/`isTransforming`.
        layerStack = newLayerStack
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: - Zoom (always integer multiples, nearest-neighbor)

    func zoomIn() {
        if let next = CanvasView.zoomLevels.first(where: { $0 > zoomScale }) {
            zoomScale = next
            updateTextEditorForZoomChange()
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    func zoomOut() {
        if let next = CanvasView.zoomLevels.last(where: { $0 < zoomScale }) {
            zoomScale = next
            updateTextEditorForZoomChange()
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
        updateTextEditorForZoomChange()
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
        // Same reasoning as `activeTool`'s own `didSet` reset (issue #20):
        // transform mode preempts every gesture, so an in-progress pen
        // stroke's buffer must not survive into it unflushed — and since
        // entering transform mode doesn't change `layerStack.activeLayer`
        // either, flush (don't discard) so the stroke's already-drawn
        // pixels land on the layer instead of disappearing. This must run
        // *before* the `transformOriginalCanvas` snapshot just below: that
        // snapshot (not `layerStack.activeLayer.canvas`) is what
        // `commitLayerTransform()` later rasterizes back onto the real
        // layer, so flushing after snapshotting would have the commit
        // silently overwrite the just-flushed stroke with the pre-flush
        // canvas.
        if isPenStrokeInProgress {
            flushPenStroke()
        }
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
        // Same reasoning as every other tool's gesture-state reset just
        // above, extended to the crop tool's own pending rectangle (issue
        // #21): entering transform mode preempts it too, and nothing has
        // been applied to any pixels by it yet, so there's nothing worth
        // preserving.
        cancelCrop()
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

    // MARK: - Crop tool (issue #21)

    /// Which handle of `cropRect`'s rectangle a crop drag grabbed — the
    /// crop tool's counterpart to `TransformHandle`, minus its `.rotate`/
    /// `.distort` cases: crop is always an axis-aligned rectangle (the
    /// issue's own plan: "回転ハンドルは無し、軸並行矩形のみ"), so there is
    /// nothing for either of those two gestures to ever grab. `.move`/
    /// `.corner`/`.edge` mean exactly what they do on `TransformHandle`.
    private enum CropHandle: Equatable {
        case move
        case corner(TransformCorner)
        case edge(TransformEdge)
    }

    /// The crop tool's very first drag — before any pending rectangle
    /// exists yet — in view-space coordinates, the same rubber-band shape
    /// `selectionDragStart`/`selectionDragCurrent` track for the rectangle/
    /// ellipse select tools. Once this drag ends (`mouseUp`), its bounds
    /// seed `cropRect` below and both of these go back to `nil` for the
    /// remainder of the gesture.
    private var cropDragStart: NSPoint?
    private var cropDragCurrent: NSPoint?

    /// The crop tool's pending rectangle, once the user has dragged one out
    /// — `nil` before that first drag completes. Reuses `LayerTransform`'s
    /// center+size shape purely as a convenient "rectangle in canvas
    /// pixel space" value type: `rotation` and every `distort*` offset are
    /// never touched by any crop code path, so `cropRect.corners` always
    /// comes out as a plain axis-aligned rectangle — the same reduction
    /// `LayerTransform.corners` makes for any transform with `rotation == 0`
    /// and no distortion — and `resizeByCorner`/`resizeByEdge` above (round
    /// 1's math, before rotation/distortion existed) can be reused as-is for
    /// the handle-resize drags below. Non-`nil` for the remainder of the
    /// gesture — handle resize, interior move, Enter/double-click to
    /// confirm (`commitCrop()`), Escape to cancel (`cancelCrop()`) —
    /// mirroring `activeTransform`'s own "non-`nil` means mid-adjustment"
    /// convention, just tool-gated (`activeTool == .crop`) instead of
    /// preempting every tool the way `activeTransform` does.
    private var cropRect: LayerTransform?
    /// Same role as `transformDragHandle`, captured at the crop drag's
    /// `mouseDown` and consumed (read every `mouseDragged`, cleared at
    /// `mouseUp`) the same way.
    private var cropDragHandle: CropHandle?
    /// Same role as `transformDragStartPoint`.
    private var cropDragStartPoint: NSPoint?
    /// Same role as `transformDragStartTransform` — `cropRect`'s value at
    /// the moment the current handle/move drag started, so every
    /// `mouseDragged` recomputes from this snapshot plus the drag's total
    /// movement so far, rather than accumulating per-event deltas.
    private var cropDragStartRect: LayerTransform?

    /// Whether the *current* `cropRect` came from an initial drag so short
    /// it needed floor-clamping to `transformMinimumSize` on either axis —
    /// i.e. the user never actually dragged out a rectangle, they just
    /// clicked (issue #21 review must-1). A plain click and the first tap of
    /// a double-click are indistinguishable to `mouseDown`/`mouseUp` up to
    /// this point, so without this flag the second tap's `mouseDown` —
    /// landing well inside the freshly-created minimum-size rectangle, since
    /// its half-width/half-height comfortably clear
    /// `transformHandleHitRadius` — reads as an ordinary `.move`-handle
    /// double-click and `commitCrop()` fires immediately: a destructive,
    /// unconfirmed crop down to 4x4 pixels with no drag and no rectangle
    /// ever actually shown to the user.
    ///
    /// `mouseUp` sets this the moment it creates `cropRect` from the initial
    /// drag (see that branch below); `mouseDown`'s double-click check
    /// refuses to `commitCrop()` while it's `true`, falling through to the
    /// ordinary single-click handle-drag start instead — so the second tap
    /// just starts adjusting the rectangle rather than confirming it
    /// outright. Cleared back to `false` the moment the user actually
    /// adjusts the rectangle via a handle/move drag (`mouseDragged`'s
    /// crop-handle branch): from that point on the pending rectangle
    /// reflects a deliberate choice, so a later double-click confirming it
    /// is legitimate again, the same way it always safely is for
    /// `activeTransform`'s own identity-rectangle double-click convention.
    /// `cancelCrop()` resets this too, for the same "safe to call at any
    /// point in the gesture" reason it resets every other piece of crop
    /// state.
    private var cropRectWasClamped = false

    /// Hit-tests a view-space click/drag-start point against `rect`'s
    /// handles and interior, at the current `zoomScale` — the crop tool's
    /// counterpart to `hitTestTransformHandle(at:transform:)`, minus that
    /// method's rotate-ring and Option+corner distort handling: `rect`
    /// (`cropRect`) stays axis-aligned for the whole gesture (see its own
    /// doc comment), so this reduces to exactly `hitTestTransformHandle`'s
    /// own `rotation == 0`, no-distortion code path — corners/edges checked
    /// first (within `transformHandleHitRadius`), a point inside the
    /// rectangle otherwise is `.move`, and a point outside it entirely is
    /// `nil`.
    private func hitTestCropHandle(at point: NSPoint, rect: LayerTransform) -> CropHandle? {
        let scale = CGFloat(zoomScale)
        let (corners, edges) = CanvasView.transformHandlePoints(for: rect, scale: scale)
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
        let centerView = CGPoint(x: rect.centerX * Double(scale), y: rect.centerY * Double(scale))
        let halfWidth = rect.width / 2 * Double(scale)
        let halfHeight = rect.height / 2 * Double(scale)
        let dx = Double(point.x) - centerView.x
        let dy = Double(point.y) - centerView.y
        return (abs(dx) <= halfWidth && abs(dy) <= halfHeight) ? .move : nil
    }

    /// Abandons the pending crop rectangle without touching any pixels —
    /// the crop tool's counterpart to `cancelLayerTransform()`. Resets every
    /// piece of the crop gesture's state, including the initial-drag fields
    /// (`cropDragStart`/`cropDragCurrent`), so it's safe to call at any
    /// point in the gesture (mid rubber-band drag, mid handle drag, or with
    /// a fully-formed pending rectangle) — used by `activeTool`'s own
    /// `didSet`, `beginLayerTransform()` (both preempt the crop tool
    /// entirely), `commitCrop()` (to clear its own state once the crop
    /// lands for real), the crop tool's own Escape handling in
    /// `keyDown(with:)`, and (issue #21 test-design review, via `isCropping`)
    /// every `AppDelegate` call site that can swap `layerStack` out or
    /// restore a different history snapshot out from under a pending crop:
    /// `activateActiveDocument()`, `undo()`/`redo()`, `historyPanelView
    /// .onJumpToIndex`, and `layerPanelView.willChangeActiveLayer`. Not
    /// `private` for exactly that reason — `AppDelegate` needs to call it
    /// directly, the same way it calls `cancelLayerTransform()`/
    /// `cancelPenStroke()`.
    func cancelCrop() {
        cropDragStart = nil
        cropDragCurrent = nil
        cropRect = nil
        cropDragHandle = nil
        cropDragStartPoint = nil
        cropDragStartRect = nil
        cropRectWasClamped = false
        needsDisplay = true
    }

    /// Confirms the pending crop rectangle: builds a brand-new `LayerStack`
    /// sized to `cropRect`'s bounds (each corner rounded to the nearest
    /// whole canvas pixel), with every existing layer's own pixels copied
    /// across from the corresponding region of its current canvas. Pixels
    /// the rectangle covers that fall outside the *original* canvas —
    /// possible once a handle drag has pushed an edge past it, since
    /// nothing in this file clamps `cropRect` to the canvas bounds, the same
    /// way Photoshop's own crop tool lets you drag a handle outward to pad
    /// the canvas with blank space — are simply left at the new canvas's
    /// default transparent fill, the same "nothing to sample, leave the
    /// destination untouched" rule `rasterizeTransform` already follows for
    /// layer transforms.
    ///
    /// Unlike every other confirm-style method in this file
    /// (`commitLayerTransform()`, `flushPenStroke()`, the selection tools'
    /// `mouseUp`), this can't just mutate `layerStack`/its layers in place:
    /// `LayerStack.width`/`height` are `let`, so a crop can only ever
    /// produce a whole new `LayerStack` instance — `onLayerStackReplaced`
    /// is what tells `AppDelegate` about that specifically; see its own doc
    /// comment for why that has to be a dedicated callback rather than
    /// folding into `onEditCompleted`.
    ///
    /// Also resets `selection` to `nil` (per the issue's own plan): a
    /// selection mask built for the pre-crop canvas size no longer lines up
    /// with the cropped one.
    private func commitCrop() {
        guard let cropRect else { return }
        let corners = cropRect.corners
        let minX = Int(corners.topLeft.x.rounded())
        let minY = Int(corners.topLeft.y.rounded())
        let maxX = Int(corners.bottomRight.x.rounded())
        let maxY = Int(corners.bottomRight.y.rounded())
        let newWidth = max(1, maxX - minX)
        let newHeight = max(1, maxY - minY)

        // `layer.canvas.rawPixel(x:y:)` already returns `nil` for any
        // out-of-bounds coordinate (negative or past `width`/`height`), so
        // the loop below relies on that alone rather than a redundant
        // manual bounds check — same convention `rasterizeTransform` above
        // already follows for its own "pixels outside the source, leave the
        // destination untouched" rule.
        let newLayers = layerStack.layers.map { layer -> Layer in
            let newCanvas = PixelCanvas(width: newWidth, height: newHeight, background: .clear)
            for y in 0..<newHeight {
                for x in 0..<newWidth {
                    guard let raw = layer.canvas.rawPixel(x: minX + x, y: minY + y) else { continue }
                    let color = NSColor(
                        deviceRed: Double(raw.r) / 255,
                        green: Double(raw.g) / 255,
                        blue: Double(raw.b) / 255,
                        alpha: Double(raw.a) / 255
                    )
                    newCanvas.setPixel(x: x, y: y, color: color)
                }
            }
            return Layer(
                canvas: newCanvas,
                name: layer.name,
                isVisible: layer.isVisible,
                opacity: layer.opacity,
                blendMode: layer.blendMode
            )
        }
        let newStack = LayerStack(width: newWidth, height: newHeight, layers: newLayers, activeLayerIndex: layerStack.activeLayerIndex)

        layerStack = newStack
        invalidateIntrinsicContentSize()
        selection = nil
        cancelCrop()

        onLayerStackReplaced?(newStack)
        onLayerContentChanged?()
        onEditCompleted?("切り抜き")
        needsDisplay = true
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

        // Pen stroke live preview (issue #20): `penStrokeBuffer` holds the
        // dabs stamped so far but isn't merged into the real active layer
        // until `flushPenStroke()` at `mouseUp` (see that method's doc
        // comment) — without drawing it here too, an in-progress pen stroke
        // would be invisible on screen until the mouse is released. Drawn
        // at `penBrushSettings.opacity * layerStack.activeLayer.opacity`,
        // matching exactly what `flushPenStroke()` followed by the ordinary
        // composite above would actually produce once the stroke ends, so
        // the live preview never shows something the finished stroke won't
        // — the same "preview must match the eventual commit" alpha
        // handling the layer-transform preview below already follows via
        // its own `context.setAlpha(layerStack.activeLayer.opacity)` calls.
        if let penStrokeBuffer, let previewImage = penStrokeBuffer.cgImage {
            context.saveGState()
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.setAlpha(CGFloat(penBrushSettings.opacity) * CGFloat(layerStack.activeLayer.opacity))
            context.draw(previewImage, in: destRect)
            context.restoreGState()
        }

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

        // Crop tool rubber-band preview (issue #21): the very first drag,
        // before any pending rectangle exists yet — same dashed rubber-band
        // shape as the rectangle select tool's own drag preview above, just
        // gated on `cropRect == nil` (once the drag ends, `mouseUp` promotes
        // it into `cropRect`, and the block below takes over instead).
        if activeTool == .crop, cropRect == nil, let start = cropDragStart, let current = cropDragCurrent {
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
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }
        }

        // Crop tool pending rectangle + 8-handle overlay (issue #21): the
        // same 4-corner + 4-edge-midpoint handle layout `activeTransform`'s
        // own preview draws above, minus a rotate ring (crop is
        // axis-aligned only — see `CropHandle`'s doc comment) and minus any
        // re-rasterized pixel preview, since cropping doesn't move or
        // resample any pixels until it's actually confirmed — the ordinary
        // composite already drawn at the top of this method is exactly what
        // the cropped layers will keep, just clipped to this rectangle.
        if activeTool == .crop, let cropRect {
            let scale = CGFloat(zoomScale)
            let (corners, edges) = CanvasView.transformHandlePoints(for: cropRect, scale: scale)
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
    /// confirm, transform commit, `flushPenStroke()`). `.pen`'s own
    /// `mouseUp` branch (issue #20) never actually reaches this lookup —
    /// `flushPenStroke()` fires `onEditCompleted?("ペン")` itself, the same
    /// self-contained shape `commitLayerTransform()` uses — but the case
    /// stays listed here as the accurate tool→label mapping regardless (and
    /// so the switch stays exhaustive without a redundant "never reached"
    /// comment duplicating `flushPenStroke()`'s own).
    private static func editCompletedLabel(for tool: Tool) -> String? {
        switch tool {
        case .pencil: return "鉛筆"
        case .eraser: return "消しゴム"
        case .pen: return "ペン"
        case .eyedropper, .magnifier, .rectangleSelect, .ellipseSelect, .lassoSelect, .polygonSelect, .magicWandSelect, .crop, .bucketFill, .text:
            // `.crop`'s own `commitCrop()` fires `onEditCompleted?("切り抜き")`
            // itself (issue #21), the same self-contained shape
            // `flushPenStroke()`/`commitLayerTransform()` use — this lookup
            // is never actually reached for it either. `.bucketFill`'s own
            // `mouseDown` branch fires `onEditCompleted?("塗りつぶし")` the
            // same self-contained way (issue #38, mirroring `magicWandSelect`
            // above, the other single-click tool). `.text`'s own
            // `commitTextEdit()` fires `onEditCompleted?("テキスト")` the same
            // self-contained way too (issue #42), from wherever the edit
            // actually ends (Cmd+Return, focus loss, or a fresh click
            // elsewhere) rather than from `mouseUp`.
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
    /// (unchanged by issue #10).
    private func paint(at pixel: (x: Int, y: Int)) {
        switch activeTool {
        case .pencil, .eraser:
            layerStack.activeLayer.canvas.setPixel(x: pixel.x, y: pixel.y, color: paintColor, mask: selection)
        case .pen:
            // The pen never reaches here, post-#20: `mouseDown`/
            // `mouseDragged` branch to `stampPenDab(at:)`/
            // `stampPenDabs(from:to:)` (dab-stamping into
            // `penStrokeBuffer`, merged onto the real layer at `mouseUp`'s
            // `flushPenStroke()`) before calling `paint(at:)`, mirroring
            // how the eyedropper/magnifier/selection tools below already
            // bypass this method entirely. Kept only to satisfy this
            // switch's exhaustiveness.
            return
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
        case .rectangleSelect, .ellipseSelect, .lassoSelect, .polygonSelect, .magicWandSelect, .crop, .bucketFill:
            // Same as the magnifier above: these branch to their own
            // drag/combine handling in `mouseDown`/`mouseDragged`/`mouseUp`
            // before calling `paint(at:)` (issue #11; `.crop` under issue
            // #21; `.bucketFill` under issue #38 — its whole gesture is a
            // single click resolved entirely in `mouseDown`, same as
            // `.magicWandSelect`). Kept only to satisfy this switch's
            // exhaustiveness.
            return
        case .text:
            // The text tool never reaches here either (issue #42):
            // `mouseDown`/`mouseDragged` branch to `beginTextEdit(at:)`/an
            // early return before calling `paint(at:)` — rasterization
            // happens later, from `commitTextEdit()`, not from a
            // pixel-by-pixel paint call. Kept only to satisfy this switch's
            // exhaustiveness.
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
            // Same as `paint(at:)` above: the pen never reaches here,
            // post-#20 — `mouseDragged` calls `stampPenDabs(from:to:)`
            // instead. Kept only for exhaustiveness.
            return
        case .eyedropper:
            // Same as `paint(at:)` above: the eyedropper never drags into a
            // stroke (issue #14), this exists only for exhaustiveness.
            return
        case .magnifier:
            // Same as `paint(at:)` above: the magnifier never drags into a
            // stroke (issue #13), this exists only for exhaustiveness.
            return
        case .rectangleSelect, .ellipseSelect, .lassoSelect, .polygonSelect, .magicWandSelect, .crop, .bucketFill:
            // Same as `paint(at:)` above: these never drag into a stroke
            // (issue #11; `.crop` under issue #21; `.bucketFill` under issue
            // #38, a single-click-only gesture), this exists only for
            // exhaustiveness.
            return
        case .text:
            // Same as `paint(at:)` above: the text tool never drags into a
            // stroke (issue #42), this exists only for exhaustiveness.
            return
        }
    }

    // MARK: - Pen tool (issue #20: dab-stamping, hardness/opacity/flow)

    /// Stamps one pen dab at `pixel` into `penStrokeBuffer` (issue #20),
    /// using `penBrushSettings`' current `size`/`hardness` and `flow` as the
    /// dab's own alpha — `flow`, not `opacity`: see `PenBrushSettings`'s and
    /// `flushPenStroke()`'s doc comments for why the stroke-level `opacity`
    /// cap is deliberately *not* applied per dab. A no-op if
    /// `penStrokeBuffer` is `nil` (called outside of an active pen stroke —
    /// shouldn't happen given `mouseDown`'s `.pen` branch always creates the
    /// buffer first, but this keeps the method safe to call unconditionally
    /// regardless).
    private func stampPenDab(at pixel: (x: Int, y: Int)) {
        guard let buffer = penStrokeBuffer else { return }
        buffer.drawPenDab(
            at: pixel,
            color: paintColor,
            diameter: penBrushSettings.size,
            hardness: penBrushSettings.hardness,
            alpha: penBrushSettings.flow,
            mask: selection
        )
    }

    /// Stamps a line's worth of pen dabs from `p0` to `p1`, spaced
    /// `max(1, size * 0.25)` points apart (issue #20) — the pen's
    /// dab-stamping counterpart to `paintLine(from:to:)`'s single
    /// `drawLine`/`drawAntialiasedLine` call, used by `mouseDragged`'s
    /// `.pen` branch for the segment between the previous and current
    /// dragged pixel. Always stamps `p1` itself, even when it falls short
    /// of the next full spacing interval, so a stroke's dabs never lag
    /// behind the cursor's actual position between `mouseDragged` events
    /// the way a purely interval-based walk would — mirrors `drawLine`'s
    /// own guarantee of visiting `p1` exactly.
    private func stampPenDabs(from p0: (x: Int, y: Int), to p1: (x: Int, y: Int)) {
        let spacing = Double(max(1, penBrushSettings.size * 0.25))
        let dx = Double(p1.x - p0.x)
        let dy = Double(p1.y - p0.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else {
            stampPenDab(at: p1)
            return
        }
        var traveled = spacing
        while traveled < distance {
            let t = traveled / distance
            let x = Int((Double(p0.x) + dx * t).rounded())
            let y = Int((Double(p0.y) + dy * t).rounded())
            stampPenDab(at: (x, y))
            traveled += spacing
        }
        stampPenDab(at: p1)
    }

    /// Merges the in-progress pen stroke's accumulation buffer onto the
    /// real active layer canvas at `penBrushSettings.opacity`, then
    /// discards the buffer (issue #20) — the single point where a whole pen
    /// stroke's worth of dabs actually becomes a permanent edit.
    ///
    /// Called once, from `mouseUp`'s shared pencil/eraser/pen fallback
    /// (a pen "click" with no drag is just a one-dab stroke, same as every
    /// other tool's single-click gesture) — never mid-drag:
    /// `mouseDragged`'s `.pen` branch only ever stamps more dabs into
    /// `penStrokeBuffer`, leaving the real layer untouched until this runs.
    /// This is also *why* `opacity` behaves as a whole-stroke cap rather
    /// than a per-dab one: every dab within the stroke only ever pushes
    /// `penStrokeBuffer`'s own alpha up toward `1` (via `flow`, dab by dab,
    /// through `PixelCanvas`'s standard alpha compositing), never toward
    /// `opacity` directly — scaling the *entire accumulated buffer* by
    /// `opacity` in one shot, here, is what caps the finished stroke's
    /// alpha at `opacity` regardless of how many dabs overlapped a given
    /// pixel along the way.
    ///
    /// Self-contained the same way `commitLayerTransform()` is (fires its
    /// own `onLayerContentChanged`/`onEditCompleted` — see below — rather
    /// than leaving that to whichever call site invoked it): every call
    /// site (the `mouseUp` fallback below, and every `AppDelegate` site
    /// that also auto-confirms an in-progress layer transform — see
    /// `isPenStrokeInProgress`'s doc comment) gets the same correct
    /// behavior automatically, and none of them needs to remember to fire
    /// those two callbacks itself. A no-op if `penStrokeBuffer` is `nil`
    /// (no pen stroke was in progress), so it's always safe to call
    /// unconditionally.
    ///
    /// `onEditCompleted?("ペン")` fires with the merge already applied
    /// above, so `AppDelegate.recordHistoryCheckpoint(label:)` — wired to
    /// this callback — snapshots a `layerStack` that already includes the
    /// finished stroke (issue #19). Not `private`, for the same reason
    /// `commitLayerTransform()` isn't: `AppDelegate` needs to call this
    /// directly wherever it already calls that method.
    func flushPenStroke() {
        guard let buffer = penStrokeBuffer else { return }
        layerStack.activeLayer.canvas.compositeOverlay(buffer, alpha: penBrushSettings.opacity)
        penStrokeBuffer = nil
        onLayerContentChanged?()
        onEditCompleted?("ペン")
        needsDisplay = true
    }

    /// Discards the in-progress pen stroke's accumulation buffer *without*
    /// compositing it onto the real layer (issue #20) — the pen-stroke
    /// counterpart to `cancelLayerTransform()`, for the same reason
    /// `AppDelegate.undo()`/`redo()`/`historyPanelView.onJumpToIndex` cancel
    /// (rather than commit) an in-progress layer transform: the stroke has
    /// no history entry of its own yet, so flushing it right as undo/redo
    /// swaps in a whole different snapshot would silently bake an
    /// unrecorded edit into that snapshot instead of just disappearing the
    /// way an un-recorded, in-progress edit should. Also resets
    /// `paintedDuringGesture`/`lastPixel` so that if the underlying mouse
    /// gesture is still physically in progress (the button never actually
    /// came up — cancellation reaching here at all means something else,
    /// like a keyboard shortcut, interrupted the drag), the eventual real
    /// `mouseUp` neither re-flushes anything (`penStrokeBuffer` is already
    /// `nil`) nor fires a bogus, effect-less `onEditCompleted`. A no-op if
    /// no pen stroke is in progress.
    func cancelPenStroke() {
        penStrokeBuffer = nil
        paintedDuringGesture = false
        lastPixel = nil
        needsDisplay = true
    }

    // MARK: - Text tool (issue #42)

    /// Starts a new text-edit gesture at `pixel`: drops a fresh, empty
    /// `TextToolEditorView` onto the canvas at that position and makes it
    /// first responder so typing starts immediately.
    ///
    /// The editor's on-screen font size is `textSettings.fontSize *
    /// zoomScale`, not the literal `fontSize` — it needs to visually match
    /// how big the baked-in text will look once `rasterizeText(_:at:)`
    /// renders it back down to its true canvas-pixel size, the same
    /// "screen point = canvas pixel * zoomScale" relationship every other
    /// tool's click already goes through via `pixelCoordinate(for:)`, just
    /// applied in the opposite direction here (canvas-pixel setting → view
    /// point size, rather than view point click → canvas pixel).
    private func beginTextEdit(at pixel: (x: Int, y: Int)) {
        let editor = TextToolEditorView(frame: .zero)
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = true
        editor.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        editor.textColor = foregroundColor
        editor.font = CanvasView.resolvedFont(family: textSettings.fontFamily, size: textSettings.fontSize * CGFloat(zoomScale))
        editor.layoutOrientation = textSettings.isVertical ? .vertical : .horizontal
        // "What you type is what gets baked" (issue #42) — matches the
        // rest of this app's dot-exact philosophy more closely than a word
        // processor's helpful-but-surprising auto-substitutions would.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        // Auto-grows with typed content instead of scrolling/clipping (no
        // enclosing `NSScrollView` here, unlike `ToolboxView`/
        // `DocumentTabBarView`) — `textDidChange(_:)` below drives the
        // actual resize once layout catches up with each edit.
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: Self.textEditorMaxSize, height: Self.textEditorMaxSize)
        editor.minSize = NSSize(width: Self.textEditorMinWidth, height: Self.textEditorMinHeight)
        editor.maxSize = NSSize(width: Self.textEditorMaxSize, height: Self.textEditorMaxSize)
        editor.delegate = self
        editor.onCancel = { [weak self] in self?.cancelTextEdit() }
        editor.onCommit = { [weak self] in self?.commitTextEdit() }

        let origin = NSPoint(x: CGFloat(pixel.x) * CGFloat(zoomScale), y: CGFloat(pixel.y) * CGFloat(zoomScale))
        editor.frame = NSRect(origin: origin, size: NSSize(width: Self.textEditorMinWidth, height: Self.textEditorMinHeight))

        addSubview(editor)
        window?.makeFirstResponder(editor)

        textEditor = editor
        textInsertionPixel = pixel
        needsDisplay = true
    }

    /// Grows `textEditor`'s frame to fit its current content (issue #42),
    /// capped at `textEditorMaxSize` on each axis — called from
    /// `textDidChange(_:)` every time the typed text changes.
    ///
    /// For horizontal text (`textSettings.isVertical == false`) this keeps
    /// the frame's top-left corner fixed and grows right/down, matching
    /// `beginTextEdit(at:)`'s initial placement (click point = top-left).
    ///
    /// For vertical text (review should-1), traditional Japanese tategaki
    /// adds new columns to the *left* of the first one, not the right — so
    /// anchoring at top-left like the horizontal case would grow the
    /// overlay the wrong way as more columns appear. Anchoring at top-right
    /// instead (fixed `origin.x + width`, `origin.y` unchanged) keeps the
    /// first column's on-screen position stable and lets the frame expand
    /// leftward, which is why only `origin.x` — not `origin.y` — is
    /// recomputed below.
    ///
    /// Caveats (unverified — no macOS machine in this dev environment):
    /// 1. This top-right anchoring is based on the general convention that
    ///    tategaki columns run right-to-left; whether AppKit's
    ///    `NSTextView.layoutOrientation = .vertical` (set in
    ///    `beginTextEdit(at:)`) actually lays out new columns in that
    ///    direction, or the opposite, has **not** been confirmed by running
    ///    this on real macOS/AppKit.
    /// 2. If AppKit's actual column direction turns out to be the reverse
    ///    of what's assumed here, the only consequence is a cosmetic one:
    ///    the *live editing overlay* would grow the wrong way on screen.
    ///    The committed result is unaffected — `rasterizeText(_:at:)` bakes
    ///    the final text using its own independent offscreen `NSTextView`,
    ///    a separate code path from this overlay, so the actual pixels
    ///    written to the layer do not depend on this method at all.
    /// 3. kako-jun: if vertical editing on real macOS shows the overlay
    ///    growing in a visually wrong direction, this `if
    ///    textSettings.isVertical` branch is the only place to look —
    ///    nothing else in the text tool depends on this assumption.
    private func resizeTextEditorToFitContent() {
        guard let editor = textEditor, let layoutManager = editor.layoutManager, let textContainer = editor.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let width = min(Self.textEditorMaxSize, max(Self.textEditorMinWidth, usedRect.width + editor.textContainerInset.width * 2))
        let height = min(Self.textEditorMaxSize, max(Self.textEditorMinHeight, usedRect.height + editor.textContainerInset.height * 2))
        var frame = editor.frame
        if textSettings.isVertical {
            let topRightX = frame.origin.x + frame.size.width
            frame.size = NSSize(width: width, height: height)
            frame.origin.x = topRightX - width
        } else {
            frame.size = NSSize(width: width, height: height)
        }
        editor.frame = frame
        needsDisplay = true
    }

    /// Re-anchors `textEditor`'s on-screen frame origin and font size to
    /// the current `zoomScale` (issue #42 review should-2) — called from
    /// every call site that assigns to `zoomScale` (`zoomIn()`/
    /// `zoomOut()`/`setZoomScale(_:)`). Without this, an in-progress text
    /// edit's overlay stays pinned to whatever `zoomScale` was in effect
    /// when `beginTextEdit(at:)` ran, drifting out of alignment with the
    /// canvas's own on-screen scale as soon as the user zooms mid-edit.
    ///
    /// A no-op if no text edit is in progress. Recomputes the frame origin
    /// with the exact same "canvas pixel * zoomScale" formula
    /// `beginTextEdit(at:)` uses (from `textInsertionPixel`, the original
    /// click location), re-resolves `editor.font` at the new zoomed size
    /// the same way `beginTextEdit(at:)` does, then defers to
    /// `resizeTextEditorToFitContent()` to grow/shrink the frame size to
    /// match the now-differently-sized text.
    ///
    /// Also resets `frame.size` back to `(textEditorMinWidth,
    /// textEditorMinHeight)` before that hand-off (issue #42 review round 2
    /// should-1) — not just `frame.origin` — so `resizeTextEditorToFitContent()`
    /// always starts from the same "just-clicked" state `beginTextEdit(at:)`
    /// itself leaves the frame in, rather than mixing a freshly-recomputed
    /// (new-zoom) `origin` with a stale (old-zoom) `size` left over from
    /// whatever zoom level was active the last time the overlay auto-grew.
    /// Left unfixed, that mix corrupts the vertical-writing branch of
    /// `resizeTextEditorToFitContent()` specifically: it derives its new
    /// `origin.x` from `frame.origin.x + frame.size.width` (the previous
    /// top-right corner), so an old-zoom `width` added to a new-zoom
    /// `origin.x` lands the overlay's top-right corner nowhere near either
    /// zoom level's correct position. The horizontal branch only overwrites
    /// `frame.size` outright, so it was never affected — but resetting size
    /// here is harmless for it too, since the following
    /// `resizeTextEditorToFitContent()` call recomputes `frame.size` from
    /// the current text content regardless of what it started at.
    private func updateTextEditorForZoomChange() {
        guard let editor = textEditor, let pixel = textInsertionPixel else { return }
        var frame = editor.frame
        frame.origin = NSPoint(x: CGFloat(pixel.x) * CGFloat(zoomScale), y: CGFloat(pixel.y) * CGFloat(zoomScale))
        frame.size = NSSize(width: Self.textEditorMinWidth, height: Self.textEditorMinHeight)
        editor.frame = frame
        editor.font = CanvasView.resolvedFont(family: textSettings.fontFamily, size: textSettings.fontSize * CGFloat(zoomScale))
        resizeTextEditorToFitContent()
    }

    /// Ends the current text-edit gesture and bakes what was typed into the
    /// active layer's pixels (issue #42) — the text tool's equivalent of
    /// `flushPenStroke()`. A no-op if nothing is being edited, or if the
    /// editor was left empty (an empty string has nothing to rasterize and
    /// leaves the layer untouched, same as `cancelTextEdit()`).
    ///
    /// Clears `textEditor`/`textInsertionPixel` *before* touching the view
    /// hierarchy: `editor.removeFromSuperview()` below can itself trigger
    /// `textDidEndEditing(_:)` (first-responder resignation as part of
    /// removal), which calls straight back into this same method — with
    /// `textEditor` already `nil` by then, that reentrant call's own `guard
    /// let editor = textEditor` bails out immediately instead of
    /// rasterizing the same text a second time.
    ///
    /// Called from `activeTool`'s own `didSet`, `mouseDown`'s `.text`
    /// branch, `TextToolEditorView.onCommit` (Cmd+Return), and
    /// `textDidEndEditing(_:)` (focus loss) — and, mirroring
    /// `flushPenStroke()`, from every `AppDelegate` call site that already
    /// commits an in-progress pen stroke before swapping `layerStack` out
    /// from under it (see `isTextEditing`'s own doc comment for the full
    /// list). Not `private`, for the same reason `flushPenStroke()` isn't.
    func commitTextEdit() {
        guard let editor = textEditor, let pixel = textInsertionPixel else { return }
        textEditor = nil
        textInsertionPixel = nil
        editor.delegate = nil
        let text = editor.string
        editor.removeFromSuperview()
        needsDisplay = true

        guard !text.isEmpty else { return }

        rasterizeText(text, at: pixel)
        onLayerContentChanged?()
        onEditCompleted?("テキスト")
        needsDisplay = true
    }

    /// Ends the current text-edit gesture without touching any layer
    /// pixels (issue #42, Escape) — same reentrancy guard as
    /// `commitTextEdit()` above, for the same reason.
    ///
    /// Also called, mirroring `cancelPenStroke()`, from every `AppDelegate`
    /// call site that already cancels an in-progress pen stroke rather than
    /// committing it — `undo()`/`redo()`/`historyPanelView.onJumpToIndex` —
    /// since a not-yet-committed text edit was never itself recorded as a
    /// history entry either. Not `private`, for the same reason
    /// `cancelPenStroke()` isn't.
    func cancelTextEdit() {
        guard let editor = textEditor else { return }
        textEditor = nil
        textInsertionPixel = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        needsDisplay = true
    }

    /// Renders `text` at `textSettings`' own literal canvas-pixel font size
    /// (not multiplied by `zoomScale`, unlike `textEditor`'s on-screen
    /// font — see `beginTextEdit(at:)`) and composites it onto the active
    /// layer with its top-left corner at `pixel` (issue #42).
    ///
    /// Builds a second, throwaway `NSTextView` rather than rasterizing
    /// `textEditor` itself: `textEditor`'s own on-screen size reflects the
    /// current `zoomScale`, and downsampling *that* rendering back down to
    /// canvas-pixel resolution would either blur (interpolated) or
    /// alias/moiré (nearest-neighbor) an antialiased glyph edge, depending
    /// on which resampling `interpolationQuality` was used — rendering
    /// fresh, directly at the true 1-canvas-pixel-per-point size, avoids
    /// that resampling step entirely and produces the same crisp result
    /// regardless of what zoom level the user happened to be editing at.
    ///
    /// Font rendering can't be made fully non-anti-aliased the way the
    /// pencil/bucket-fill's `setPixel`/`drawLine` are (CLAUDE.md's classic-
    /// tool "no anti-aliasing" policy) — `NSTextView`'s own glyph
    /// rendering always anti-aliases — so this leaves that default
    /// smoothing alone rather than fighting it into a jagged, harder-to-
    /// read result; `PixelCanvas.compositeImage(_:at:mask:)` draws the
    /// glyph bitmap into a `rect` sized directly from the image's own
    /// `width`/`height` — a 1:1 pixel correspondence, so no scaling
    /// happens there and `interpolationQuality`'s value (this path never
    /// actually sets it) has no effect on the result — the glyph bitmap is
    /// composited onto the layer pixel-for-pixel, with no additional
    /// scaling blur layered on top of its own anti-aliasing.
    private func rasterizeText(_ text: String, at pixel: (x: Int, y: Int)) {
        let rasterView = NSTextView(frame: .zero)
        rasterView.isRichText = false
        rasterView.string = text
        rasterView.font = CanvasView.resolvedFont(family: textSettings.fontFamily, size: textSettings.fontSize)
        rasterView.textColor = foregroundColor
        rasterView.drawsBackground = false
        rasterView.layoutOrientation = textSettings.isVertical ? .vertical : .horizontal
        rasterView.textContainerInset = .zero
        rasterView.textContainer?.lineFragmentPadding = 0
        rasterView.isVerticallyResizable = true
        rasterView.isHorizontallyResizable = true
        rasterView.textContainer?.widthTracksTextView = false
        rasterView.textContainer?.heightTracksTextView = false
        rasterView.textContainer?.containerSize = NSSize(width: 10_000, height: 10_000)

        guard let layoutManager = rasterView.layoutManager, let textContainer = rasterView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let width = max(1, Int(usedRect.width.rounded(.up)))
        let height = max(1, Int(usedRect.height.rounded(.up)))
        let viewRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        rasterView.frame = viewRect

        // Built by hand — not `bitmapImageRepForCachingDisplay(in:)` — at
        // exactly `width`x`height` *pixels*: that convenience constructor
        // sizes its bitmap using the view's own backing scale factor,
        // which would be `2.0` were this view ever attached to a Retina
        // window, silently doubling the baked-in text's pixel size
        // relative to what `textSettings.fontSize` says. `rasterView` here
        // is never attached to any window, so pinning the bitmap's pixel
        // dimensions explicitly (matching `viewRect`'s point size 1:1, via
        // `bitmap.size` below) is what actually guarantees "this many
        // canvas pixels tall" — not an incidental default.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        bitmap.size = viewRect.size
        rasterView.cacheDisplay(in: viewRect, to: bitmap)
        guard let cgImage = bitmap.cgImage else { return }

        layerStack.activeLayer.canvas.compositeImage(cgImage, at: pixel, mask: selection)
    }

    /// Resolves `family` (a font *family* name, e.g. what
    /// `OptionBarView.showTextOptions`' popup lists via `NSFontManager
    /// .shared.availableFontFamilies`) into a concrete `NSFont`, falling
    /// back to the system font at the same size if the family doesn't
    /// resolve to an installed font — defensive against a `TextToolSettings
    /// .fontFamily` value that no longer matches anything installed (a
    /// font removed since it was picked, or state loaded from a different
    /// machine).
    private static func resolvedFont(family: String, size: CGFloat) -> NSFont {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont(name: family, size: size)
            ?? NSFont.systemFont(ofSize: size)
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
        // Crop tool confirm/cancel (issue #21) — same Enter/Escape
        // convention as the polygon tool's own handling just below, but
        // gated on a pending `cropRect` existing rather than a non-empty
        // vertex list. Known, deliberate gap (issue #21 review nit-1,
        // locked in by
        // `testCropTool_escapeDuringInitialRubberBandDragBeforeCropRectExists_isIgnoredByKeyDown`):
        // Escape pressed *during* the very first rubber-band drag, before
        // `mouseUp` has promoted it into `cropRect`, falls through to
        // `super.keyDown(with:)` and does nothing — there is no in-progress
        // rectangle yet for it to cancel.
        if activeTool == .crop, cropRect != nil {
            switch event.keyCode {
            case 53: // Escape: cancel the pending crop, no canvas change.
                cancelCrop()
            case 36, 76: // Return / keypad Enter: confirm.
                commitCrop()
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
        if activeTool == .bucketFill {
            // A single click is the whole gesture (issue #38), mirroring
            // `magicWandSelect` above: the flood-fill region is computed
            // and painted right here, with no `mouseDragged`/`mouseUp`
            // handling of its own.
            //
            // Flood-fills the active layer's own pixels — same reasoning
            // as `magicWandSelect` above: this has to look at (and here,
            // overwrite) the exact pixels `paint(at:)` would, not a
            // flattened composite that could span other layers.
            let canvas = layerStack.activeLayer.canvas
            var fillMask = SelectionMask.magicWand(
                startX: pixel.x, startY: pixel.y,
                colorAt: { x, y in canvas.rawPixel(x: x, y: y) },
                tolerance: bucketFillTolerance,
                width: layerStack.width, height: layerStack.height
            )
            // A selection restricts every editing tool to its own bounds
            // (same "intersect with the active selection" pattern
            // `ImageAdjustments.apply`'s `mask` parameter and issue #11's
            // other tools already follow) — intersecting the flood-fill
            // region with it here means the fill can never spill paint
            // outside the selection, even into same-colored pixels that
            // lie beyond it.
            if let selection {
                fillMask = fillMask.intersected(with: selection)
            }
            // No anti-aliasing (CLAUDE.md: bucket fill is a classic tool,
            // dot-exact pixels only) — every pixel in `fillMask` is
            // overwritten outright with the solid foreground color, via
            // `PixelCanvas.setPixel(x:y:color:mask:)`'s own mask-restricted
            // overload (the same selection-masking mechanism issue #11's
            // other painting tools already use) rather than a bespoke
            // `fillMask.contains` guard duplicating that check here.
            //
            // Scanning only `fillMask.boundingBox` — instead of every pixel
            // in `0..<layerStack.width` / `0..<layerStack.height`
            // unconditionally — means a fill on a small flood-filled region
            // of a large canvas costs proportional to that region's own
            // extent, not the whole canvas. `boundingBox` is `nil` only
            // when `fillMask` selected nothing at all (e.g. an empty
            // intersection with `selection` above), in which case there is
            // nothing to paint.
            if let box = fillMask.boundingBox {
                for y in box.minY...box.maxY {
                    for x in box.minX...box.maxX {
                        canvas.setPixel(x: x, y: y, color: foregroundColor, mask: fillMask)
                    }
                }
            }
            onLayerContentChanged?()
            // Same self-contained shape as `magicWandSelect` above (issue
            // #19): bucket fill's whole gesture is this one click, so
            // `onEditCompleted` fires right here rather than in `mouseUp`.
            onEditCompleted?("塗りつぶし")
            needsDisplay = true
            return
        }
        if activeTool == .crop {
            let point = convert(event.locationInWindow, from: nil)
            if let cropRect {
                // A pending rectangle already exists (issue #21): hit-test
                // its handles/interior, mirroring `activeTransform`'s own
                // `mouseDown` handling above, minus the rotate-ring/Option+
                // corner distort cases neither this tool nor
                // `hitTestCropHandle` supports. A double-click on the
                // rectangle's interior confirms outright, the same
                // "done adjusting, apply it now" convention `activeTransform`
                // already uses.
                let handle = hitTestCropHandle(at: point, rect: cropRect)
                // A double-click confirms outright — but only once the
                // pending rectangle actually reflects a user-specified
                // range, not the click-sized default `mouseUp` falls back to
                // when the initial drag was too short to clear
                // `transformMinimumSize` (issue #21 review must-1): a
                // drag-less click immediately followed by the second tap of
                // a double-click would otherwise land squarely inside that
                // freshly-created minimum-size rectangle and auto-commit it
                // with no confirmation ever shown — see
                // `cropRectWasClamped`'s own doc comment. Falling through to
                // the ordinary single-click handle-drag start below instead
                // just lets the user keep adjusting it, exactly as any other
                // click on the rectangle would.
                if event.clickCount == 2, handle == .move, !cropRectWasClamped {
                    commitCrop()
                    return
                }
                cropDragHandle = handle
                cropDragStartPoint = point
                cropDragStartRect = cropRect
                return
            }
            // No pending rectangle yet: starts a fresh rubber-band drag, the
            // same shape as `rectangleSelect`'s own `mouseDown` (issue #11)
            // — the dragged bounds seed `cropRect` once this drag ends, in
            // `mouseUp`.
            cropDragStart = point
            cropDragCurrent = point
            return
        }
        if activeTool == .text {
            // A click while already editing text (issue #42) commits the
            // current edit first — same "flush before starting the next
            // one" rule the pen tool's leftover-buffer check above follows
            // — then starts a brand new one at the freshly clicked
            // position. In practice this branch rarely finds `textEditor`
            // still non-nil: `window?.makeFirstResponder(self)` at the very
            // top of this method already resigns the editor's first-
            // responder status for any click that lands outside of it
            // (clicks *inside* it are delivered straight to the editor
            // subview instead, never reaching `CanvasView.mouseDown` at
            // all), which fires `textDidEndEditing(_:)` and commits it
            // before this line ever runs — this check is a defensive
            // fallback for whenever that doesn't hold.
            if isTextEditing {
                commitTextEdit()
            }
            beginTextEdit(at: pixel)
            return
        }
        if activeTool == .pen {
            // Flushes (never cancels) a leftover `penStrokeBuffer` before
            // starting the new one. Normally `mouseDown`→`mouseDragged`→
            // `mouseUp` always pairs up, so `penStrokeBuffer` should already
            // be `nil` here — but AppKit doesn't guarantee that: a window
            // deactivation/focus loss mid-stroke can swallow the matching
            // `mouseUp`, and the next `mouseDown` (possibly after other
            // gesture-state resets that don't touch `penStrokeBuffer`, e.g.
            // a later click while `activeTool` never actually changed) would
            // otherwise silently replace the buffer below, discarding
            // whatever the previous, never-confirmed stroke had already
            // drawn. Flushing (not `cancelPenStroke()`) is the safe
            // direction here — same as `activeTool`'s own `didSet` and
            // `beginLayerTransform()` (issue #20 review): none of these
            // three change `layerStack.activeLayer`, so the right move is
            // always to keep the already-drawn pixels rather than lose
            // them.
            if penStrokeBuffer != nil {
                flushPenStroke()
            }
            // Starts a fresh accumulation buffer for this stroke (issue
            // #20) — nothing is written to the real active layer until
            // `mouseUp`'s `flushPenStroke()`; see `penStrokeBuffer`'s own
            // doc comment. Skips `paint(at:)`/the generic fallback below
            // entirely, same as every other special-cased tool above.
            penStrokeBuffer = PixelCanvas(width: layerStack.width, height: layerStack.height, background: .clear)
            stampPenDab(at: pixel)
            paintedDuringGesture = true
            lastPixel = pixel
            needsDisplay = true
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
        if let startRect = cropDragStartRect, let handle = cropDragHandle, let startPoint = cropDragStartPoint {
            // A handle/move drag on the already-pending crop rectangle
            // (issue #21) — same recompute-from-drag-start-plus-total-
            // movement convention as `activeTransform`'s own handle drags
            // above, reusing `resizeByCorner`/`resizeByEdge` outright since
            // `cropRect` never carries any rotation for either to correct
            // for (see `cropRect`'s own doc comment).
            //
            // Reaching here at all means the user is actively dragging a
            // handle to adjust the rectangle (issue #21 review must-1) —
            // even when `cropRect` started out click-sized (see
            // `cropRectWasClamped`), it no longer counts as an unadjusted
            // default once a real drag has touched it, so a later
            // double-click confirming it becomes legitimate again.
            cropRectWasClamped = false
            let point = convert(event.locationInWindow, from: nil)
            let scale = CGFloat(zoomScale)
            let dx = Double((point.x - startPoint.x) / scale)
            let dy = Double((point.y - startPoint.y) / scale)
            switch handle {
            case .move:
                var rect = startRect
                rect.centerX = startRect.centerX + dx
                rect.centerY = startRect.centerY + dy
                cropRect = rect
            case .corner(let corner):
                cropRect = CanvasView.resizeByCorner(corner, start: startRect, dx: dx, dy: dy, keepAspect: event.modifierFlags.contains(.shift))
            case .edge(let edge):
                cropRect = CanvasView.resizeByEdge(edge, start: startRect, dx: dx, dy: dy)
            }
            needsDisplay = true
            return
        }
        if cropRect != nil {
            // The drag started outside the rectangle/handles entirely —
            // deliberately inert, mirroring `activeTransform`'s identical
            // guard above.
            return
        }
        if activeTool == .crop {
            // The crop tool's very first drag (issue #21), before any
            // pending rectangle exists yet — just records the current point
            // for `draw(_:)`'s rubber-band preview; the actual rectangle
            // isn't built until this drag ends, in `mouseUp`.
            cropDragCurrent = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            return
        }
        if activeTool == .text {
            // The text tool has no drag gesture of its own (issue #42): a
            // click starts editing (`mouseDown`) and everything after that
            // is handled by the overlay `textEditor` subview itself, which
            // — being a real `NSTextView` — receives its own mouse events
            // directly and never routes them through `CanvasView` at all.
            // This branch only exists to keep a drag that started on
            // `CanvasView` (i.e. outside the editor, before any editor
            // exists yet) from falling through to the generic pencil/eraser
            // paint fallback below.
            return
        }
        if activeTool == .pen {
            // Stamps more dabs into `penStrokeBuffer` (issue #20); the real
            // active layer stays untouched until `mouseUp`'s
            // `flushPenStroke()` — see `mouseDown`'s `.pen` branch and
            // `penStrokeBuffer`'s own doc comment. Bails out up front if
            // `penStrokeBuffer` is already `nil`: normally impossible mid-
            // drag (every pen stroke starts in `mouseDown`, which creates
            // it), but `cancelPenStroke()` can clear it out from under a
            // still-physically-in-progress drag (undo/redo, a document/tab
            // switch, etc. — see that method's own doc comment) — without
            // this guard, a `mouseDragged` arriving after that would still
            // flag `paintedDuringGesture = true` for a stroke that no
            // longer exists, and `mouseUp` would then fire a bogus,
            // effect-less `onEditCompleted`.
            guard penStrokeBuffer != nil else { return }
            let pixel = pixelCoordinate(for: event)
            if let last = lastPixel {
                stampPenDabs(from: last, to: pixel)
            } else {
                stampPenDab(at: pixel)
            }
            paintedDuringGesture = true
            lastPixel = pixel
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
        if activeTool == .text {
            // Nothing to do here (issue #42): `mouseDown` already handled
            // the whole gesture (committing any previous edit, then
            // `beginTextEdit(at:)`), and the eventual commit/cancel happens
            // later, asynchronously, from the overlay editor's own key
            // handling (`TextToolEditorView.onCommit`/`onCancel`) or focus
            // loss (`textDidEndEditing(_:)`) — none of which are this
            // `mouseUp`. Returning early here just keeps this click from
            // falling into the generic pencil/eraser fallback below.
            return
        }
        if activeTool == .pen {
            // The pen's whole stroke becomes a real edit only now (issue
            // #20): `mouseDown`/`mouseDragged` only ever stamped dabs into
            // `penStrokeBuffer`, so the active layer itself is still
            // exactly as it was before this stroke started until
            // `flushPenStroke()` merges the buffer in — see that method's
            // own doc comment for why it's self-contained (fires
            // `onLayerContentChanged`/`onEditCompleted` itself) rather than
            // this branch firing them separately, the way the generic
            // pencil/eraser fallback below does via `editCompletedLabel`.
            // A pen "click" with no drag reaches here too and is just a
            // one-dab stroke, same as every other tool's single-click
            // gesture.
            flushPenStroke()
            paintedDuringGesture = false
            lastPixel = nil
            return
        }
        if activeTool == .crop {
            if let start = cropDragStart, let current = cropDragCurrent {
                // Ends the crop tool's very first drag (issue #21): the
                // dragged bounds become `cropRect`, so the *next* click
                // starts adjusting it via handles instead of dragging out a
                // brand new rectangle (see `mouseDown`'s own `if let
                // cropRect` branch).
                defer {
                    cropDragStart = nil
                    cropDragCurrent = nil
                    needsDisplay = true
                }
                let p0 = CanvasView.pixelCoordinate(forPoint: start, zoomScale: zoomScale)
                let p1 = CanvasView.pixelCoordinate(forPoint: current, zoomScale: zoomScale)
                // Pixel index `x` occupies the continuous range `[x, x + 1)`
                // (same convention the ellipse-select branch above
                // documents), so the dragged rectangle's continuous bounds
                // run from `min` to `max + 1` on each axis. Clamped to at
                // least `transformMinimumSize` on each axis (same floor
                // `resizeByCorner`/`resizeByEdge` already enforce for
                // handle-driven resizes), so even a stray click with no real
                // drag still produces a small, adjustable pending rectangle
                // rather than a degenerate zero-area one.
                let minX = min(p0.x, p1.x)
                let maxX = max(p0.x, p1.x) + 1
                let minY = min(p0.y, p1.y)
                let maxY = max(p0.y, p1.y) + 1
                let rawWidth = Double(maxX - minX)
                let rawHeight = Double(maxY - minY)
                let width = max(Self.transformMinimumSize, rawWidth)
                let height = max(Self.transformMinimumSize, rawHeight)
                // Recorded from the *raw*, pre-clamp extent (issue #21
                // review must-1): a drag whose raw width or height already
                // needed flooring up to `transformMinimumSize` means the
                // user didn't really drag out a rectangle at all — see
                // `cropRectWasClamped`'s own doc comment for why that
                // disqualifies the very next double-click from
                // auto-confirming.
                cropRectWasClamped = rawWidth < Self.transformMinimumSize || rawHeight < Self.transformMinimumSize
                cropRect = LayerTransform(centerX: Double(minX + maxX) / 2, centerY: Double(minY + maxY) / 2, width: width, height: height)
                return
            }
            // Ends a handle/move drag on the already-pending rectangle
            // (issue #21) — mirrors `activeTransform`'s own `mouseUp`
            // above: never confirms by itself, just resets the drag state
            // so the next `mouseDown` starts a fresh hit test.
            cropDragHandle = nil
            cropDragStartPoint = nil
            cropDragStartRect = nil
            return
        }
        guard activeTool == .magnifier else {
            // Pencil/eraser strokes fire `onEditCompleted` here, at the
            // gesture's actual end, and only if something was actually
            // painted during it (issue #19) — a click that landed on the
            // eyedropper/polygon-select/magic-wand tools also reaches this
            // fallback (they handle their own gesture end elsewhere or take
            // no `mouseUp` action at all), but `editCompletedLabel` returns
            // `nil` for those, so nothing fires. `.pen`/`.crop` never reach
            // here: they return from their own branches above.
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

// MARK: - Text tool overlay editor delegate (issue #42)

extension CanvasView: NSTextViewDelegate {
    /// Live-resizes the text tool's overlay editor as its content grows —
    /// `TextToolEditorView` has no enclosing `NSScrollView` of its own (see
    /// `beginTextEdit(at:)`), so without this the box would stay pinned at
    /// its initial `textEditorMinWidth`/`textEditorMinHeight` size and clip
    /// anything typed past it.
    func textDidChange(_ notification: Notification) {
        guard let changedView = notification.object as? NSTextView, changedView === textEditor else { return }
        resizeTextEditorToFitContent()
    }

    /// Commits the text tool's in-progress edit on focus loss — fires
    /// whenever `textEditor` resigns first responder for any reason
    /// (clicking elsewhere on the canvas, clicking a toolbox button,
    /// switching documents, etc.), the "フォーカス喪失で確定" half of the
    /// issue's commit rule (the other half, Cmd+Return, is
    /// `TextToolEditorView.onCommit` instead). Guarded by object identity
    /// the same way `textDidChange(_:)` above is, and safe to call even
    /// after `commitTextEdit()`/`cancelTextEdit()` already ran — see
    /// `commitTextEdit()`'s own doc comment on why removing the editor from
    /// the view hierarchy can itself re-trigger this notification.
    func textDidEndEditing(_ notification: Notification) {
        guard let endedView = notification.object as? NSTextView, endedView === textEditor else { return }
        commitTextEdit()
    }
}
