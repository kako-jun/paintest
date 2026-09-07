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
    ///
    /// `moveLayer` reorders `layers` by tracking the active layer's object
    /// identity, not its index, so the active layer is not guaranteed to be
    /// the topmost element of the array — it can equally well end up with
    /// non-active layers both below *and* above it in stacking order. A
    /// single flattened "background" image can't represent that: it would
    /// have to flatten the above-active layers on top of the active layer's
    /// own contents, which is exactly backwards. So this instead caches the
    /// two flattenable halves separately, each already bottom-to-top within
    /// itself: `below` is `layers[0..<activeLayerIndex]` and `above` is
    /// `layers[(activeLayerIndex + 1)...]`. Either (or both) is `nil` when
    /// its range has no visible layer, so a document with nothing on one
    /// side of the active layer never pays for an empty flatten.
    ///
    /// `excludedIndex` records which layer `below`/`above` are split around,
    /// so a stale cache built for a since-changed `activeLayerIndex` is
    /// never mistaken for a fresh one.
    ///
    /// Invalidated (reset to `nil`) by anything that can change what a
    /// non-active layer looks like, or which layer counts as "non-active":
    /// `setVisibility`, `setOpacity`, `addLayer`, `removeLayer`,
    /// `duplicateLayer`, `moveLayer`, and `activeLayerIndex` itself changing
    /// (see its `didSet` above).
    private var backgroundCompositeCache: (excludedIndex: Int, below: CGImage?, above: CGImage?)?

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
        layers[index].setVisible(isVisible)
        backgroundCompositeCache = nil
    }

    func setOpacity(_ opacity: Double, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].setOpacity(opacity)
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
    /// active one, split into the `below`/`above` halves
    /// `backgroundCompositeCache` remembers (see its doc for why one
    /// flattened image can't represent this once `moveLayer` has put
    /// non-active layers on both sides of the active layer), then, only for
    /// "exclude nothing", draw the active layer back in between them. A
    /// mouseDragged-driven redraw therefore only ever re-flattens the one
    /// layer that could have changed, instead of every visible layer — and
    /// always redraws `below` → (active layer) → `above` in that order, so
    /// the active layer lands wherever it actually sits in the stack rather
    /// than always on top.
    /// Any other `excludedIndex` (no current call site uses one, but this
    /// is a public API kept general) bypasses the cache entirely and falls
    /// back to a full from-scratch composite, so the cache — which is only
    /// ever keyed to `activeLayerIndex` — is never built for, or
    /// contaminated by, an unrelated exclusion.
    ///
    /// The result is pixel-identical to compositing all layers from scratch
    /// in one pass: `below` and `above` are drawn at `alpha = 1` onto an
    /// otherwise-empty context, which source-over blending reproduces
    /// exactly (the destination contributes nothing while its alpha is 0),
    /// and the active layer is drawn between them with its own opacity via
    /// `context.setAlpha(_:)`, exactly as the single-pass loop would do for
    /// that same layer — so the combined `below` → active → `above` order
    /// always matches `layers`' own bottom-to-top order.
    func compositeImage(excludingLayerAtIndex excludedIndex: Int? = nil) -> CGImage? {
        if excludedIndex != nil && excludedIndex != activeLayerIndex {
            // Not a pattern any current call site uses — don't touch or
            // build the cache, just do the old full recomposite.
            return renderComposite(excluding: excludedIndex)
        }

        let below: CGImage?
        let above: CGImage?
        if let cache = backgroundCompositeCache, cache.excludedIndex == activeLayerIndex {
            below = cache.below
            above = cache.above
        } else {
            let renderedBelow = renderRange(layers[0..<activeLayerIndex])
            let renderedAbove = renderRange(layers[(activeLayerIndex + 1)...])
            backgroundCompositeCache = (excludedIndex: activeLayerIndex, below: renderedBelow, above: renderedAbove)
            below = renderedBelow
            above = renderedAbove
        }

        if excludedIndex == activeLayerIndex {
            // issue #9's transform-preview path: `below` then `above`, in
            // that order, already *is* "every visible layer except the
            // active one" in correct stacking order — exactly what was
            // asked for.
            return composite(below: below, activeLayer: nil, above: above)
        }

        return composite(below: below, activeLayer: activeLayer, above: above)
    }

    /// Flattens every visible layer except `excludedIndex` (bottom-to-top,
    /// plain source-over, no exclusion at all when `excludedIndex` is
    /// `nil`) into a brand-new image, from scratch. This is the same loop
    /// `compositeImage` always ran before issue #17 — kept only for the one
    /// exclusion pattern the cache doesn't cover (an `excludedIndex` other
    /// than `activeLayerIndex`). `backgroundCompositeCache`'s two halves are
    /// built by `renderRange` instead, since a single "everything except
    /// `excludedIndex`" flatten can't represent them separately.
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

    /// Flattens a bottom-to-top slice of `layers` (skipping any that aren't
    /// visible), the same way `renderComposite` flattens the whole array,
    /// but returns `nil` instead of an empty/transparent image when the
    /// slice contains no visible layer at all — so a document with nothing
    /// on one side of the active layer never pays for creating a context
    /// and drawing nothing into it. Used to build the `below` and `above`
    /// halves of `backgroundCompositeCache`.
    private func renderRange(_ slice: ArraySlice<Layer>) -> CGImage? {
        guard slice.contains(where: { $0.isVisible }) else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = Self.makeCompositeContext(width: width, height: height, colorSpace: colorSpace)
        else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        for layer in slice where layer.isVisible {
            guard let cgImage = layer.canvas.cgImage else { continue }
            context.setAlpha(CGFloat(layer.opacity))
            context.draw(cgImage, in: rect)
        }

        return context.makeImage()
    }

    /// Draws, into a fresh context, whichever of `below`, `activeLayer` and
    /// `above` are non-`nil` — in that order, bottom-to-top — which is
    /// exactly the stacking order `layers` itself uses, since `below` and
    /// `above` are `layers[0..<activeLayerIndex]` and
    /// `layers[(activeLayerIndex + 1)...]` respectively (see
    /// `backgroundCompositeCache`'s doc). `below`/`above` are already
    /// pre-flattened images, drawn at full strength (`alpha = 1`);
    /// `activeLayer`, when passed, is drawn respecting its own `isVisible`
    /// and `opacity` — exactly as `renderComposite`'s loop would when it
    /// reaches that layer's turn. Passing `nil` for any of the three simply
    /// skips that draw, so e.g. a single-layer document (nothing below or
    /// above the active layer) draws only the active layer itself.
    private func composite(below: CGImage?, activeLayer: Layer?, above: CGImage?) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = Self.makeCompositeContext(width: width, height: height, colorSpace: colorSpace)
        else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        if let below {
            context.setAlpha(1)
            context.draw(below, in: rect)
        }

        if let activeLayer, activeLayer.isVisible, let cgImage = activeLayer.canvas.cgImage {
            context.setAlpha(CGFloat(activeLayer.opacity))
            context.draw(cgImage, in: rect)
        }

        if let above {
            context.setAlpha(1)
            context.draw(above, in: rect)
        }

        return context.makeImage()
    }

    /// A blank ARGB context sized to the document, with the same
    /// nearest-neighbour / no-antialiasing compositing policy every
    /// `LayerStack` flatten has always used (see `compositeImage`'s doc).
    /// Shared by `renderComposite`, `renderRange`, and `composite` so every
    /// compositing pass stays in lockstep.
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
