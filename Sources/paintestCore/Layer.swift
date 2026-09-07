import AppKit

/// A single editable layer inside a `LayerStack`: a pixel canvas plus the
/// per-layer compositing state (display name, visibility, opacity).
///
/// `Layer` itself does not know its position in the stack — ordering is
/// `LayerStack`'s responsibility.
final class Layer {
    let canvas: PixelCanvas
    var name: String

    /// Both setters are `private` — the only code allowed to change these
    /// after construction is `setVisible`/`setOpacity` below, which
    /// `LayerStack.setVisibility`/`setOpacity` call. This closes off the
    /// direct-assignment path (`layerStack.layers[i].isVisible = ...`) that
    /// would otherwise let `backgroundCompositeCache` go stale without
    /// anything invalidating it — the same "derived state disagrees with
    /// its source" shape as issues #9/#19.
    private(set) var isVisible: Bool
    private(set) var opacity: Double {
        didSet { opacity = max(0, min(1, opacity)) }
    }

    init(canvas: PixelCanvas, name: String, isVisible: Bool = true, opacity: Double = 1.0) {
        self.canvas = canvas
        self.name = name
        self.isVisible = isVisible
        self.opacity = max(0, min(1, opacity))
    }

    /// Changes `isVisible`. Only `LayerStack.setVisibility(_:at:)` calls
    /// this, so every visibility change is guaranteed to also invalidate
    /// `LayerStack.backgroundCompositeCache`.
    func setVisible(_ isVisible: Bool) {
        self.isVisible = isVisible
    }

    /// Changes `opacity` (still clamped to `0...1` by the `didSet` above).
    /// Only `LayerStack.setOpacity(_:at:)` calls this, so every opacity
    /// change is guaranteed to also invalidate
    /// `LayerStack.backgroundCompositeCache`.
    func setOpacity(_ opacity: Double) {
        self.opacity = opacity
    }
}
