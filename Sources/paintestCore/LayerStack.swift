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

    /// Which layer is the current target of interactive pixel edits
    /// (`setPixel`/`drawLine` etc. only ever touch `activeLayer.canvas` —
    /// every other layer's pixels are frozen while the user is drawing).
    ///
    /// The `didSet` exists purely to invalidate `backgroundCompositeCache`
    /// whenever this changes — including the direct assignment
    /// `LayerPanelView.selectLayer(at:)` makes (`layerStack.activeLayerIndex
    /// = index`), which doesn't go through any `LayerStack` method. Swift
    /// calls `didSet` on every assignment, even one that reassigns the same
    /// value the property already held, so an unconditional invalidation
    /// here never misses a real change — the worst case is one avoidable
    /// cache rebuild, which is far cheaper than serving a stale composite.
    /// `didSet` on a stored property is not invoked for the *initial* value
    /// given to it inside `init` (only for later re-assignments), but
    /// `backgroundCompositeCache` already starts out `nil`, so that
    /// distinction doesn't matter here either way.
    var activeLayerIndex: Int {
        didSet { backgroundCompositeCache = nil }
    }
    let width: Int
    let height: Int

    /// Cache of "every visible layer except `activeLayerIndex`, already
    /// flattened" — the part of `compositeImage(excludingLayerAtIndex:)`'s
    /// result that interactive editing (which only ever mutates
    /// `activeLayer.canvas`) cannot change from one frame to the next.
    /// `excludedIndex` records which layer the cached `image` excludes, so a
    /// stale cache built for a since-changed `activeLayerIndex` is never
    /// mistaken for a fresh one.
    ///
    /// Invalidated (reset to `nil`) by anything that can change what a
    /// non-active layer looks like, or which layer counts as "non-active":
    /// `setVisibility`, `setOpacity`, `addLayer`, `removeLayer`,
    /// `duplicateLayer`, `moveLayer`, and `activeLayerIndex` itself changing
    /// (see its `didSet` above).
    private var backgroundCompositeCache: (excludedIndex: Int, image: CGImage)?

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
        backgroundCompositeCache = nil
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
        backgroundCompositeCache = nil
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
        backgroundCompositeCache = nil
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
        backgroundCompositeCache = nil
    }

    func setVisibility(_ isVisible: Bool, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].isVisible = isVisible
        backgroundCompositeCache = nil
    }

    func setOpacity(_ opacity: Double, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].opacity = opacity
        backgroundCompositeCache = nil
    }

    // MARK: - Duplication

    /// Returns a fully independent deep copy of this `LayerStack` — every
    /// layer's `canvas` is duplicated via `PixelCanvas.copy()`, not shared
    /// with the original (issue #19: `HistoryManager` snapshots the whole
    /// stack on every recorded edit, and must never let a later live edit
    /// reach back into a stored snapshot, or vice versa — see issue #9's
    /// "reused a reference" bug this app already hit once).
    ///
    /// This goes through `init(width:height:layers:activeLayerIndex:)`, so
    /// the new instance's `backgroundCompositeCache` starts out `nil` like
    /// any other freshly-built `LayerStack` — the cache is deliberately not
    /// part of what gets copied here, since it's a derived value (always
    /// re-derivable from `layers`/`activeLayerIndex`), not state.
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
    /// on every compositing context this creates, mirroring `CanvasView`'s
    /// existing "no anti-aliasing, no interpolation" policy so the
    /// flattened result stays exactly as dot-exact as any individual layer.
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
    ///
    /// Issue #17: interactive pixel edits (`setPixel`/`drawLine` etc.) only
    /// ever land on `activeLayer.canvas`, so every non-active layer's
    /// contents are frozen for the whole duration of a drag. That means the
    /// two exclusion patterns `CanvasView` actually calls this with —
    /// "exclude nothing" and "exclude `activeLayerIndex`" — both reduce to
    /// the *same* underlying work: flatten every visible layer except the
    /// active one (which `backgroundCompositeCache` remembers), then, only
    /// for "exclude nothing", draw the active layer back on top. A
    /// mouseDragged-driven redraw therefore only ever re-flattens the one
    /// layer that could have changed, instead of every visible layer.
    /// Any other `excludedIndex` (no current call site uses one, but this
    /// is a public API kept general) bypasses the cache entirely and falls
    /// back to a full from-scratch composite, so the cache — which is only
    /// ever keyed to `activeLayerIndex` — is never built for, or
    /// contaminated by, an unrelated exclusion.
    ///
    /// The result is pixel-identical to compositing all layers from scratch
    /// in one pass: the cached background is drawn at `alpha = 1` onto an
    /// otherwise-empty context, which source-over blending reproduces
    /// exactly (the destination contributes nothing while its alpha is 0),
    /// and the active layer is then drawn on top with its own opacity via
    /// `context.setAlpha(_:)`, exactly as the single-pass loop would do for
    /// that same layer.
    func compositeImage(excludingLayerAtIndex excludedIndex: Int? = nil) -> CGImage? {
        if excludedIndex != nil && excludedIndex != activeLayerIndex {
            // Not a pattern any current call site uses — don't touch or
            // build the cache, just do the old full recomposite.
            return renderComposite(excluding: excludedIndex)
        }

        let background: CGImage
        if let cache = backgroundCompositeCache, cache.excludedIndex == activeLayerIndex {
            background = cache.image
        } else {
            guard let rendered = renderComposite(excluding: activeLayerIndex) else { return nil }
            backgroundCompositeCache = (excludedIndex: activeLayerIndex, image: rendered)
            background = rendered
        }

        if excludedIndex == activeLayerIndex {
            // issue #9's transform-preview path: the cache already *is*
            // "every visible layer except the active one" — exactly what
            // was asked for — so hand it back untouched.
            return background
        }

        return compositeActiveLayer(onto: background)
    }

    /// Flattens every visible layer except `excludedIndex` (bottom-to-top,
    /// plain source-over, no exclusion at all when `excludedIndex` is
    /// `nil`) into a brand-new image, from scratch. This is the same loop
    /// `compositeImage` always ran before issue #17 — used directly for any
    /// exclusion pattern the cache doesn't cover, and to (re)build
    /// `backgroundCompositeCache` itself.
    private func renderComposite(excluding excludedIndex: Int?) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = Self.makeCompositeContext(width: width, height: height, colorSpace: colorSpace)
        else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        for (index, layer) in layers.enumerated() where layer.isVisible && index != excludedIndex {
            guard let cgImage = layer.canvas.cgImage else { continue }
            context.setAlpha(CGFloat(layer.opacity))
            context.draw(cgImage, in: rect)
        }

        return context.makeImage()
    }

    /// Draws `background` (assumed to already be "every visible layer
    /// except the active one", pre-flattened) into a fresh context at full
    /// strength, then draws the active layer on top — respecting its own
    /// visibility and `opacity` — exactly as `renderComposite` would when
    /// it reaches the active layer's turn in its loop.
    private func compositeActiveLayer(onto background: CGImage) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = Self.makeCompositeContext(width: width, height: height, colorSpace: colorSpace)
        else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setAlpha(1)
        context.draw(background, in: rect)

        let layer = activeLayer
        if layer.isVisible, let cgImage = layer.canvas.cgImage {
            context.setAlpha(CGFloat(layer.opacity))
            context.draw(cgImage, in: rect)
        }

        return context.makeImage()
    }

    /// A blank ARGB context sized to the document, with the same
    /// nearest-neighbour / no-antialiasing compositing policy every
    /// `LayerStack` flatten has always used (see `compositeImage`'s doc).
    /// Shared by `renderComposite` and `compositeActiveLayer` so both
    /// compositing passes stay in lockstep.
    private static func makeCompositeContext(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
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
        return context
    }

    /// PNG bytes for the flattened (single-image) composite. Used for the
    /// existing "PNG export" save path, which cannot represent layers.
    func flattenedPNGData() -> Data? {
        guard let image = compositeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
