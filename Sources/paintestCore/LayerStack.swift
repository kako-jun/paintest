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
    /// non-active layer looks like, or which layer counts as "non-active".
    /// `setVisibility`/`setOpacity` do this with their own explicit reset,
    /// since neither ever touches `activeLayerIndex`. `addLayer`,
    /// `removeLayer`, `duplicateLayer` and `moveLayer` need no such explicit
    /// reset of their own: every one of them unconditionally reassigns
    /// `activeLayerIndex` (past its early-return guard, if it has one) —
    /// even when the value it computes is the same index `activeLayerIndex`
    /// already held — and that assignment's `didSet` (see above) invalidates
    /// the cache on their behalf.
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
            opacity: source.opacity,
            blendMode: source.blendMode
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
        layers[index].setVisible(isVisible)
        backgroundCompositeCache = nil
    }

    func setOpacity(_ opacity: Double, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].setOpacity(opacity)
        backgroundCompositeCache = nil
    }

    /// Changes a layer's blend mode (issue #37). Same explicit-invalidation
    /// treatment as `setVisibility`/`setOpacity` above: a blend-mode change
    /// alters what a non-active layer contributes to the composite, so
    /// `backgroundCompositeCache` (keyed only to `activeLayerIndex`, not to
    /// any layer's blend mode) must be dropped every time.
    func setBlendMode(_ blendMode: LayerBlendMode, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].setBlendMode(blendMode)
        backgroundCompositeCache = nil
    }

    // MARK: - Merging (issue #40)

    /// Merges the layer at `index` down into the layer directly beneath it
    /// (`index - 1`), replacing both with a single new layer positioned
    /// where the lower one was. No-op if `index` is `0` (there's nothing
    /// beneath the bottom-most layer) or out of range.
    ///
    /// The two layers are drawn bottom-then-top into a fresh, initially
    /// transparent canvas — each respecting its own `isVisible`/`opacity`/
    /// `blendMode` (see `mergedCanvas(lower:upper:width:height:)`) — the
    /// same per-layer draw `renderComposite`'s own loop performs for any
    /// two adjacent layers. The merged layer's own `opacity` is then reset
    /// to `1.0`: how transparent the two original layers were *relative to
    /// each other* has already been baked into the resulting canvas's own
    /// per-pixel alpha by that draw, so re-applying either original opacity
    /// again on top would double it.
    ///
    /// `blendMode`, unlike `opacity`, is carried over unchanged from the
    /// *lower* layer, not reset to `.normal`: the merged layer takes over
    /// the lower layer's own slot in the stack (`layers[lowerIndex] =
    /// mergedLayer` below), and that slot's blend mode is what describes
    /// how its contents relate to whatever still sits further beneath it —
    /// something this isolated two-layer draw never sees or bakes in.
    /// Force-resetting it to `.normal` here would silently sever that
    /// relationship: e.g. L0 (`.normal`) / L1 (`.multiply`) / L2
    /// (`.normal`) — merging L2 into L1 must leave the merged layer still
    /// `.multiply` against L0, or L0 would stop showing through underneath
    /// it at all.
    ///
    /// This reproduces the original pair's contribution to the rest of the
    /// stack *exactly* whenever both layers use `.normal` blend mode —
    /// `compositeImage`'s own doc comment already establishes that plain
    /// alpha ("over") compositing is associative this way, regardless of
    /// either layer's opacity. For a non-`.normal` blend mode on either
    /// layer this is a documented approximation, not an exact merge:
    /// `multiply`/`screen`/`overlay` compute their result from the *real*
    /// destination beneath them, which during this isolated two-layer draw
    /// is an empty/transparent canvas — not whatever actually sits below
    /// `index - 1` in the full stack. This matches Photoshop-equivalent
    /// output for the common cases (nothing here uses a non-normal blend
    /// mode, the upper layer is fully opaque, or the lower layer sits on an
    /// effectively opaque backdrop) — but when the upper layer is
    /// semi-transparent *and* a non-normal blend mode is involved, a single
    /// merged layer plus a single carried-over blend mode cannot always
    /// reproduce the original pair's exact look against whatever sits
    /// further below. General-purpose editors like Photoshop carry the same
    /// kind of limitation for "merge down"/"flatten"; reworking this into an
    /// exact general-case merge is a deliberately out-of-scope rewrite
    /// (kako-jun decision, issue #40 self-review must-2) — current
    /// behavior stays, thoroughly documented, with only the merged layer's
    /// own carried-forward metadata (this `blendMode` fix) corrected.
    ///
    /// The merged layer takes the lower layer's own `name`, matching
    /// Photoshop's own "merge down" convention of keeping the name of the
    /// layer that survives in-place.
    func mergeDown(at index: Int) {
        guard index >= 1, layers.indices.contains(index) else { return }
        let lowerIndex = index - 1
        guard let mergedCanvas = LayerStack.mergedCanvas(lower: layers[lowerIndex], upper: layers[index], width: width, height: height) else { return }
        let mergedLayer = Layer(canvas: mergedCanvas, name: layers[lowerIndex].name, isVisible: true, opacity: 1, blendMode: layers[lowerIndex].blendMode)
        layers.remove(at: index)
        layers[lowerIndex] = mergedLayer
        // Always a real change (`index >= 1` above guarantees `lowerIndex
        // != index`, and `activeLayerIndex` necessarily held one of those
        // two values or neither before this call), so this always
        // triggers `activeLayerIndex`'s own `didSet` — same
        // "unconditional reassignment invalidates the cache on this
        // method's behalf" reasoning `addLayer`/`removeLayer`/
        // `duplicateLayer`/`moveLayer` already rely on (see
        // `backgroundCompositeCache`'s own doc comment).
        activeLayerIndex = lowerIndex
    }

    /// Merges every layer into one (issue #40's "画像を統合" / Flatten
    /// Image): repeatedly merges the topmost layer down until only one
    /// remains, matching `mergeDown`'s own per-pair rules (and exactness
    /// caveat) at each step. A hidden layer's contents are discarded
    /// rather than baked in, matching Photoshop's own Flatten Image —
    /// `mergeDown`'s own `isVisible` gate already gives this for free at
    /// every step, since a hidden layer draws nothing into the merge.
    ///
    /// The sole remaining layer is always left fully opaque, `.normal`-
    /// blended, and visible — explicitly, not just as a side effect of
    /// `mergeDown`'s own output already being that way (issue #37
    /// integration): a single-layer stack never enters `mergeDown`'s loop
    /// at all, so a starting document with exactly one, non-default layer
    /// (partial opacity, non-normal blend, or hidden) still needs this
    /// normalization applied directly. Keeps the surviving layer's own
    /// `name`, same as `mergeDown` does for each pair it merges.
    func flatten() {
        while layers.count > 1 {
            mergeDown(at: layers.count - 1)
        }
        setVisibility(true, at: 0)
        setOpacity(1, at: 0)
        setBlendMode(.normal, at: 0)
        activeLayerIndex = 0
    }

    /// Draws `lower` then `upper` (each respecting its own `isVisible`/
    /// `opacity`/`blendMode`) into a single, fresh transparent canvas —
    /// the building block `mergeDown` uses to flatten one pair of adjacent
    /// layers. See `mergeDown`'s own doc comment for the exactness caveat
    /// around non-`.normal` blend modes.
    private static func mergedCanvas(lower: Layer, upper: Layer, width: Int, height: Int) -> PixelCanvas? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = makeCompositeContext(width: width, height: height, colorSpace: colorSpace)
        else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if lower.isVisible, let lowerImage = lower.canvas.cgImage {
            context.setAlpha(CGFloat(lower.opacity))
            context.setBlendMode(lower.blendMode.cgBlendMode)
            context.draw(lowerImage, in: rect)
        }
        if upper.isVisible, let upperImage = upper.canvas.cgImage {
            context.setAlpha(CGFloat(upper.opacity))
            context.setBlendMode(upper.blendMode.cgBlendMode)
            context.draw(upperImage, in: rect)
        }
        guard let mergedImage = context.makeImage() else { return nil }

        // Round-trips through an actual PNG encode/decode (the same
        // technique `PaintestDocument`'s save/load already relies on)
        // rather than reading `mergedImage`'s premultiplied bytes
        // directly: `PixelCanvas` only knows how to ingest actual PNG
        // data via `load(from:)` — see that method's own doc comment on
        // why it specifically expects straight, not premultiplied, alpha.
        let rep = NSBitmapImageRep(cgImage: mergedImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        return PixelCanvas.load(from: pngData)
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
            Layer(
                canvas: layer.canvas.copy(),
                name: layer.name,
                isVisible: layer.isVisible,
                opacity: layer.opacity,
                blendMode: layer.blendMode
            )
        }
        return LayerStack(width: width, height: height, layers: copiedLayers, activeLayerIndex: activeLayerIndex)
    }

    // MARK: - Resizing (issue #39)

    /// Rebuilds every layer's pixel content at a new pixel resolution —
    /// "画像解像度": every layer is resampled independently, nearest-neighbor
    /// (CLAUDE.md's default "ドット単位でぼけない編集" policy — no smoothing),
    /// from this stack's current `width`/`height` to `newWidth`/`newHeight`.
    /// Layer order/name/`isVisible`/`opacity`/`blendMode` and
    /// `activeLayerIndex` all carry over unchanged; only each layer's own
    /// pixel content and this stack's own `width`/`height` change.
    ///
    /// Returns a brand-new `LayerStack` rather than mutating this one in
    /// place: `width`/`height` are `let` constants (a `LayerStack` can't
    /// change its own dimensions after construction), so the caller is
    /// expected to swap this stack out for the returned one — the same
    /// `LayerStack`-replacement pattern `CanvasView.commitCrop()` already
    /// uses for issue #21's crop tool.
    func resampled(toWidth newWidth: Int, toHeight newHeight: Int) -> LayerStack {
        let clampedWidth = max(1, newWidth)
        let clampedHeight = max(1, newHeight)
        let sourceWidth = width
        let sourceHeight = height
        let newLayers = layers.map { layer -> Layer in
            let newCanvas = PixelCanvas(width: clampedWidth, height: clampedHeight, background: .clear)
            for y in 0..<clampedHeight {
                // Nearest-neighbor source row: which source pixel a
                // destination pixel samples from, found by scaling the
                // destination index back into source space and flooring
                // (integer division does the flooring here) — the same
                // "which source pixel does this destination pixel show"
                // mapping a point-sampled resize always uses.
                let sourceY = min(sourceHeight - 1, (y * sourceHeight) / clampedHeight)
                for x in 0..<clampedWidth {
                    let sourceX = min(sourceWidth - 1, (x * sourceWidth) / clampedWidth)
                    guard let raw = layer.canvas.rawPixel(x: sourceX, y: sourceY) else { continue }
                    newCanvas.setPixel(x: x, y: y, color: NSColor(
                        deviceRed: Double(raw.r) / 255, green: Double(raw.g) / 255,
                        blue: Double(raw.b) / 255, alpha: Double(raw.a) / 255
                    ))
                }
            }
            return Layer(canvas: newCanvas, name: layer.name, isVisible: layer.isVisible, opacity: layer.opacity, blendMode: layer.blendMode)
        }
        return LayerStack(width: clampedWidth, height: clampedHeight, layers: newLayers, activeLayerIndex: activeLayerIndex)
    }

    /// Changes this stack's canvas dimensions without resampling any
    /// existing pixel — "カンバスサイズ": every layer's existing pixels are
    /// copied as-is into a new, differently-sized canvas at the position
    /// `anchor` specifies (Photoshop's own 9-point anchor grid — see
    /// `CanvasAnchor`), with any newly-added area left transparent and any
    /// pixel that falls outside the new bounds discarded. Unlike
    /// `resampled(toWidth:toHeight:)` above, nothing is ever scaled: a
    /// pixel that survives the resize keeps its exact original color.
    ///
    /// Same "returns a new `LayerStack`, doesn't mutate in place" shape as
    /// `resampled(toWidth:toHeight:)`, for the same reason.
    func resized(toWidth newWidth: Int, toHeight newHeight: Int, anchor: CanvasAnchor) -> LayerStack {
        let clampedWidth = max(1, newWidth)
        let clampedHeight = max(1, newHeight)
        let offsetX = Int((anchor.horizontalFraction * Double(clampedWidth - width)).rounded())
        let offsetY = Int((anchor.verticalFraction * Double(clampedHeight - height)).rounded())
        let sourceWidth = width
        let sourceHeight = height
        let newLayers = layers.map { layer -> Layer in
            let newCanvas = PixelCanvas(width: clampedWidth, height: clampedHeight, background: .clear)
            for y in 0..<sourceHeight {
                let destY = y + offsetY
                guard destY >= 0, destY < clampedHeight else { continue }
                for x in 0..<sourceWidth {
                    let destX = x + offsetX
                    guard destX >= 0, destX < clampedWidth else { continue }
                    guard let raw = layer.canvas.rawPixel(x: x, y: y) else { continue }
                    newCanvas.setPixel(x: destX, y: destY, color: NSColor(
                        deviceRed: Double(raw.r) / 255, green: Double(raw.g) / 255,
                        blue: Double(raw.b) / 255, alpha: Double(raw.a) / 255
                    ))
                }
            }
            return Layer(canvas: newCanvas, name: layer.name, isVisible: layer.isVisible, opacity: layer.opacity, blendMode: layer.blendMode)
        }
        return LayerStack(width: clampedWidth, height: clampedHeight, layers: newLayers, activeLayerIndex: activeLayerIndex)
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

        // Issue #37: unlike opacity, blend modes other than `.normal` are
        // NOT associative under source-over compositing — `multiply`,
        // `screen` and `overlay` all compute their result from the *actual*
        // destination pixels beneath a layer, not from "whatever an
        // otherwise-empty context happens to hold". The `below`/`above`
        // split cache pre-flattens each half starting from a blank
        // context, which is only equivalent to a single sequential pass
        // when every layer composites with plain alpha blending (see this
        // method's own doc for that proof). So whenever any layer uses a
        // non-normal blend mode, skip the cache entirely and always fall
        // back to the blend-mode-correct single-pass `renderComposite`,
        // which draws every layer sequentially onto the one real
        // destination. This trades away issue #17's caching win only for
        // documents that actually use a non-normal blend mode; an
        // all-`.normal` document keeps the fast path unchanged.
        if layers.contains(where: { $0.blendMode != .normal }) {
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
            context.setBlendMode(layer.blendMode.cgBlendMode)
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
    ///
    /// No `setBlendMode` call here (unlike `renderComposite`): `compositeImage`
    /// only ever reaches the cache-building branch that calls this when
    /// every layer in the whole stack is `.normal` (issue #37) — a
    /// non-normal blend mode anywhere bypasses the cache and goes straight
    /// to `renderComposite` instead, since blend modes aren't associative
    /// across the below/active/above split the way plain alpha is.
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
