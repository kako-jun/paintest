import AppKit

/// Displays a `PixelCanvas` at an integer zoom factor and routes mouse
/// input into pencil strokes.
///
/// The view is flipped (origin top-left, y grows downward) so that pixel
/// row 0 in `PixelCanvas` maps directly onto the view's top row with no
/// extra coordinate flipping anywhere in the drawing or hit-testing code.
final class CanvasView: NSView {
    private(set) var canvas: PixelCanvas
    private(set) var zoomScale: Int = 4 {
        didSet { onZoomChanged?(zoomScale) }
    }

    var penColor: NSColor = .black
    var onZoomChanged: ((Int) -> Void)?

    static let zoomLevels = [1, 2, 4, 8, 16, 32]
    private var lastPixel: (x: Int, y: Int)?

    override var isFlipped: Bool { true }

    init(canvas: PixelCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: canvas.width * zoomScale, height: canvas.height * zoomScale)
    }

    func replaceCanvas(_ newCanvas: PixelCanvas) {
        canvas = newCanvas
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let image = canvas.cgImage else { return }

        // Dot-perfect scaling: no interpolation, no anti-aliasing, anywhere
        // in this transfer path.
        context.interpolationQuality = .none
        context.setShouldAntialias(false)

        let destRect = CGRect(
            x: 0,
            y: 0,
            width: canvas.width * zoomScale,
            height: canvas.height * zoomScale
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

    override func mouseDown(with event: NSEvent) {
        let pixel = pixelCoordinate(for: event)
        canvas.setPixel(x: pixel.x, y: pixel.y, color: penColor)
        lastPixel = pixel
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pixel = pixelCoordinate(for: event)
        if let last = lastPixel {
            canvas.drawLine(from: last, to: pixel, color: penColor)
        } else {
            canvas.setPixel(x: pixel.x, y: pixel.y, color: penColor)
        }
        lastPixel = pixel
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        lastPixel = nil
    }
}
