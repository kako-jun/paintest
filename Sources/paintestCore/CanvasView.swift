import AppKit

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
    var activeTool: Tool = .pencil
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

    static let zoomLevels = [1, 2, 4, 8, 16, 32]
    static let defaultZoomScale = 4
    /// The pen's fixed stroke width — the pencil paints crisp 1px-at-a-time
    /// strokes while the pen paints wider, anti-aliased ones, and this
    /// constant is what makes that difference visible on screen. This is a
    /// temporary fixed value (issue #10); a real brush-size control lands
    /// with issue #20.
    private static let penLineWidth: CGFloat = 3
    private var lastPixel: (x: Int, y: Int)?

    override var isFlipped: Bool { true }

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
            layerStack.activeLayer.canvas.setPixel(x: pixel.x, y: pixel.y, color: paintColor)
        case .pen:
            layerStack.activeLayer.canvas.drawAntialiasedDot(at: pixel, color: paintColor, diameter: Self.penLineWidth)
        case .eyedropper:
            // The eyedropper never reaches here: `mouseDown`/`mouseDragged`
            // branch to `sampleColor(at:)` before calling `paint(at:)`
            // (issue #14). Kept only to satisfy this switch's exhaustiveness.
            return
        }
    }

    /// Paints a stroke between two points with the active tool's own
    /// method, mirroring `paint(at:)`'s tool switch.
    private func paintLine(from p0: (x: Int, y: Int), to p1: (x: Int, y: Int)) {
        switch activeTool {
        case .pencil, .eraser:
            layerStack.activeLayer.canvas.drawLine(from: p0, to: p1, color: paintColor)
        case .pen:
            layerStack.activeLayer.canvas.drawAntialiasedLine(from: p0, to: p1, color: paintColor, lineWidth: Self.penLineWidth)
        case .eyedropper:
            // Same as `paint(at:)` above: the eyedropper never drags into a
            // stroke (issue #14), this exists only for exhaustiveness.
            return
        }
    }

    /// Reads the color at a pixel out of the currently displayed
    /// composite — what the user actually sees, not just the active
    /// layer's own contents — so the eyedropper picks up whatever color is
    /// visible on screen, including layers stacked above/below the active
    /// one (issue #14). Returns `nil` for a pixel outside the canvas.
    private func sampleColor(at pixel: (x: Int, y: Int)) -> NSColor? {
        guard pixel.x >= 0, pixel.x < layerStack.width, pixel.y >= 0, pixel.y < layerStack.height else { return nil }
        guard let image = layerStack.compositeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.colorAt(x: pixel.x, y: pixel.y)
    }

    override func mouseDown(with event: NSEvent) {
        let pixel = pixelCoordinate(for: event)
        if activeTool == .eyedropper {
            if let pixelColor = sampleColor(at: pixel) {
                let isSecondary = event.modifierFlags.contains(.option)
                onColorPicked?(pixelColor, isSecondary)
            }
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
        lastPixel = nil
    }
}
