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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let image = layerStack.compositeImage() else { return }

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
    }

    override func keyDown(with event: NSEvent) {
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
            return
        }
        paint(at: pixel)
        lastPixel = pixel
        needsDisplay = true
        onLayerContentChanged?()
    }

    override func mouseDragged(with event: NSEvent) {
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
        lastPixel = pixel
        needsDisplay = true
        onLayerContentChanged?()
    }

    override func mouseUp(with event: NSEvent) {
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
            return
        }
        guard activeTool == .magnifier else {
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
