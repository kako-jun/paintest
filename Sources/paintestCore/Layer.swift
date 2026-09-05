import AppKit

/// A single editable layer inside a `LayerStack`: a pixel canvas plus the
/// per-layer compositing state (display name, visibility, opacity).
///
/// `Layer` itself does not know its position in the stack — ordering is
/// `LayerStack`'s responsibility.
final class Layer {
    let canvas: PixelCanvas
    var name: String
    var isVisible: Bool
    var opacity: Double {
        didSet { opacity = max(0, min(1, opacity)) }
    }

    init(canvas: PixelCanvas, name: String, isVisible: Bool = true, opacity: Double = 1.0) {
        self.canvas = canvas
        self.name = name
        self.isVisible = isVisible
        self.opacity = max(0, min(1, opacity))
    }
}
