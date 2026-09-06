import AppKit

/// Owns and orders the layers that make up a single document, and composites
/// them into the flat image `CanvasView` actually draws.
///
/// `layers` is ordered **bottom-to-top**: index `0` is the backmost layer
/// (composited first, i.e. underneath everything else), and the last index
/// is the frontmost layer (composited last, i.e. on top). `LayerPanelView`
/// displays the reverse of this order (topmost layer listed first, like
/// every other layer panel) but the array itself always stays bottom-to-top.
final class LayerStack {
    private(set) var layers: [Layer]
    var activeLayerIndex: Int
    let width: Int
    let height: Int

    /// Starts a new document with a single, opaque layer.
    init(width: Int, height: Int, background: NSColor = .white) {
        self.width = max(1, width)
        self.height = max(1, height)
        let initialCanvas = PixelCanvas(width: self.width, height: self.height, background: background)
        self.layers = [Layer(canvas: initialCanvas, name: "レイヤー1")]
        self.activeLayerIndex = 0
    }

    /// Reconstructs a stack from already-built layers (e.g. when loading a
    /// `.paintestdoc` package, or wrapping a single loaded PNG as a
    /// one-layer document). `layers` must already be in bottom-to-top order.
    /// Falls back to a single blank layer if `layers` is empty, since a
    /// `LayerStack` always has at least one layer.
    init(width: Int, height: Int, layers: [Layer], activeLayerIndex: Int = 0) {
        self.width = max(1, width)
        self.height = max(1, height)
        if layers.isEmpty {
            self.layers = [Layer(canvas: PixelCanvas(width: self.width, height: self.height), name: "レイヤー1")]
        } else {
            self.layers = layers
        }
        self.activeLayerIndex = max(0, min(activeLayerIndex, self.layers.count - 1))
    }

    var activeLayer: Layer {
        layers[activeLayerIndex]
    }

    // MARK: - Layer management

    /// Adds a new, transparent layer directly above the current active
    /// layer, and makes it the active layer.
    @discardableResult
    func addLayer(name: String? = nil) -> Layer {
        let canvas = PixelCanvas(width: width, height: height, background: .clear)
        let resolvedName = name ?? "レイヤー\(layers.count + 1)"
        let layer = Layer(canvas: canvas, name: resolvedName)
        let insertIndex = activeLayerIndex + 1
        layers.insert(layer, at: insertIndex)
        activeLayerIndex = insertIndex
        return layer
    }

    /// Removes the layer at `index`. No-ops if it's the only remaining
    /// layer — a `LayerStack` always has at least one layer — or if `index`
    /// is out of range.
    ///
    /// Like `moveLayer`, the layer that was active before the removal (if it
    /// still exists) is tracked by object identity, not by re-clamping the
    /// old index — a plain index clamp would silently point
    /// `activeLayerIndex` at the wrong layer whenever a layer *below* the
    /// active one is removed and the array shifts underneath it. If the
    /// removed layer was itself the active one, there's no previously-active
    /// layer left to find, so `activeLayerIndex` falls back to the index the
    /// removal left behind, clamped to the new array bounds.
    func removeLayer(at index: Int) {
        guard layers.count > 1, layers.indices.contains(index) else { return }
        let previouslyActive = layers[activeLayerIndex]
        layers.remove(at: index)
        if let newIndex = layers.firstIndex(where: { $0 === previouslyActive }) {
            activeLayerIndex = newIndex
        } else {
            activeLayerIndex = min(index, layers.count - 1)
        }
    }

    /// Duplicates the layer at `index`, inserting the copy directly above
    /// the original and making it active.
    @discardableResult
    func duplicateLayer(at index: Int) -> Layer? {
        guard layers.indices.contains(index) else { return nil }
        let source = layers[index]
        let duplicate = Layer(
            canvas: source.canvas.copy(),
            name: "\(source.name) のコピー",
            isVisible: source.isVisible,
            opacity: source.opacity
        )
        let insertIndex = index + 1
        layers.insert(duplicate, at: insertIndex)
        activeLayerIndex = insertIndex
        return duplicate
    }

    /// Moves the layer at `sourceIndex` to `destinationIndex`, keeping
    /// whichever layer was active tracked as active (it may not be the one
    /// that moved).
    func moveLayer(from sourceIndex: Int, to destinationIndex: Int) {
        guard layers.indices.contains(sourceIndex), layers.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        let previouslyActive = layers[activeLayerIndex]
        let layer = layers.remove(at: sourceIndex)
        layers.insert(layer, at: destinationIndex)
        activeLayerIndex = layers.firstIndex(where: { $0 === previouslyActive }) ?? activeLayerIndex
    }

    func setVisibility(_ isVisible: Bool, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].isVisible = isVisible
    }

    func setOpacity(_ opacity: Double, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].opacity = opacity
    }

    // MARK: - Duplication

    /// Returns a fully independent deep copy of this `LayerStack` — every
    /// layer's `canvas` is duplicated via `PixelCanvas.copy()`, not shared
    /// with the original (issue #19: `HistoryManager` snapshots the whole
    /// stack on every recorded edit, and must never let a later live edit
    /// reach back into a stored snapshot, or vice versa — see issue #9's
    /// "reused a reference" bug this app already hit once).
    func copy() -> LayerStack {
        let copiedLayers = layers.map { layer in
            Layer(canvas: layer.canvas.copy(), name: layer.name, isVisible: layer.isVisible, opacity: layer.opacity)
        }
        return LayerStack(width: width, height: height, layers: copiedLayers, activeLayerIndex: activeLayerIndex)
    }

    // MARK: - Compositing

    /// Flattens every visible layer, bottom-to-top, into a single image
    /// using plain source-over alpha blending (no blend modes — normal
    /// compositing only). Each layer's `opacity` is applied via
    /// `context.setAlpha(_:)`.
    ///
    /// `interpolationQuality = .none` / `setShouldAntialias(false)` are set
    /// on the compositing context itself, mirroring `CanvasView`'s existing
    /// "no anti-aliasing, no interpolation" policy so the flattened result
    /// stays exactly as dot-exact as any individual layer.
    ///
    /// `excludingLayerAtIndex` (issue #9) skips one layer's own contents
    /// entirely, still compositing every other visible layer normally.
    /// `CanvasView` uses this while a layer transform is in progress: the
    /// active layer's *unmoved* pixels would otherwise show through
    /// underneath the transform's live preview (drawn separately, at the
    /// dragged position) since the transform isn't written back to the real
    /// layer canvas until it's confirmed. Defaults to `nil` so every
    /// pre-existing call site keeps compositing all visible layers exactly
    /// as before.
    func compositeImage(excludingLayerAtIndex excludedIndex: Int? = nil) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .none
        context.setShouldAntialias(false)

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        for (index, layer) in layers.enumerated() where layer.isVisible && index != excludedIndex {
            guard let cgImage = layer.canvas.cgImage else { continue }
            context.setAlpha(CGFloat(layer.opacity))
            context.draw(cgImage, in: rect)
        }

        return context.makeImage()
    }

    /// PNG bytes for the flattened (single-image) composite. Used for the
    /// existing "PNG export" save path, which cannot represent layers.
    func flattenedPNGData() -> Data? {
        guard let image = compositeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
