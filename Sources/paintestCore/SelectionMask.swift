import AppKit

/// A pixel-space selection region — the set of pixels currently eligible for
/// editing (issue #11: "柔軟な範囲選択").
///
/// Internally a per-pixel `UInt8` *coverage* (0 = fully outside the
/// selection, 255 = fully inside, anything in between = partially inside),
/// not a plain boolean mask (issue #56: "選択範囲にフェザー・アンチエイリ
/// アスがない"). A hard-edged selection — every rectangle/ellipse/polygon/
/// magic-wand build without `feather`/`antiAlias` requested — only ever
/// produces `0`/`255` coverage values, so `contains(x:y:)` (and every
/// pre-#56 caller that only ever asked the boolean question) behaves
/// byte-for-byte the same as the old `[Bool]`-backed version. `feather`
/// (`feathered(radius:)`, a post-process Gaussian-style blur applied to any
/// built mask) and `antiAlias` (`ellipse`/`polygon`/`magicWand`'s own
/// parameter, sub-pixel-supersampling the shape's own continuous boundary)
/// are what actually produce fractional coverage — see each one's own doc
/// comment. This deliberately does NOT touch `PixelCanvas`'s "dot-exact, no
/// blur" pencil/eraser/bucket-fill drawing algorithms themselves (issue #56
/// scope) — only the *selection boundary* a tool is restricted to gets soft
/// edges; a hard-edged (feather 0, no antiAlias) selection still restricts
/// paints exactly as before.
///
/// Round 1 of 3 built masks from rectangle and ellipse marquees
/// (`rectangle(...)`/`ellipse(...)`); round 2 adds the lasso/polygon tools'
/// free-form path via `polygon(...)`; round 3 adds the magic wand's
/// flood-filled region via `magicWand(...)`. All four shape constructors
/// combine through the same `unioned`/`subtracting`/`intersected` methods
/// and trace through the same `boundaryEdges()` — deliberately shape-agnostic
/// (see its own doc comment) so none of rounds 2/3 needed any changes here to
/// reuse it.
final class SelectionMask {
    let width: Int
    let height: Int

    /// Row-major, `width * height` coverage bytes (issue #56) —
    /// `coverage[y * width + x]` is how much of pixel `(x, y)` is selected,
    /// `0...255`. A flat array (not `PixelCanvas`'s raw byte buffer) is
    /// enough here: nothing about this type needs to be an
    /// `NSBitmapImageRep` or round-trip through PNG.
    private var coverage: [UInt8]

    /// Starts with nothing selected.
    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.coverage = Array(repeating: 0, count: self.width * self.height)
    }

    private init(width: Int, height: Int, coverage: [UInt8]) {
        self.width = width
        self.height = height
        self.coverage = coverage
    }

    private func index(x: Int, y: Int) -> Int? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return y * width + x
    }

    /// Whether pixel `(x, y)` is selected *at all* — `true` for any nonzero
    /// coverage, including a feathered/anti-aliased boundary pixel that's
    /// only partially selected. Always `false` for a coordinate outside the
    /// mask's bounds — never a bounds error — so callers (e.g.
    /// `PixelCanvas`'s paint guards) can query it unconditionally. Callers
    /// that need the actual coverage fraction (issue #56's partial-alpha
    /// compositing) use `alpha(x:y:)` instead.
    func contains(x: Int, y: Int) -> Bool {
        alpha(x: x, y: y) > 0
    }

    /// This pixel's coverage, `0...255` — `0` for a coordinate outside the
    /// mask's bounds (same "never a bounds error" contract as
    /// `contains(x:y:)`). `255` means fully selected, matching every
    /// pre-#56 mask (which only ever contains `0`/`255`); values in between
    /// only occur once `feathered(radius:)` or a shape's own `antiAlias`
    /// parameter has been used.
    func alpha(x: Int, y: Int) -> UInt8 {
        guard let i = index(x: x, y: y) else { return 0 }
        return coverage[i]
    }

    /// Sets whether pixel `(x, y)` is selected — `true`/`false` collapse to
    /// full coverage (`255`) or none (`0`); there is no boolean spelling for
    /// a partial value (build one via `feathered(radius:)` or a shape's
    /// `antiAlias`/supersampling instead). Silently ignored for a coordinate
    /// outside the mask's bounds.
    func setSelected(_ selected: Bool, x: Int, y: Int) {
        guard let i = index(x: x, y: y) else { return }
        coverage[i] = selected ? 255 : 0
    }

    /// Sets pixel `(x, y)`'s raw coverage directly (issue #56) — used
    /// internally by the supersampling `antiAlias` path in
    /// `ellipse`/`polygon`/`magicWand` to record a fractional value, unlike
    /// `setSelected(_:x:y:)`'s all-or-nothing `0`/`255`. Silently ignored for
    /// a coordinate outside the mask's bounds, same as `setSelected`.
    private func setCoverage(_ value: UInt8, x: Int, y: Int) {
        guard let i = index(x: x, y: y) else { return }
        coverage[i] = value
    }

    // MARK: - Duplication

    /// Returns an independent deep copy of this mask (issue #19 self-review
    /// should-3). `SelectionMask` is a reference type with a mutating
    /// `setSelected(_:x:y:)` method, so `HistoryManager` copies in/out the
    /// same way it already does for `LayerStack` — see that type's own
    /// `copy()` doc comment — preventing a later live selection edit from
    /// reaching back into a stored history entry, or vice versa.
    func copy() -> SelectionMask {
        SelectionMask(width: width, height: height, coverage: coverage)
    }

    // MARK: - Shape construction

    /// A filled rectangle selection between two pixel corners (inclusive of
    /// both `(x0, y0)` and `(x1, y1)` — the two corners need not be given in
    /// any particular order, e.g. either can be the drag's start or end
    /// point). Pixels outside `0..<width` / `0..<height` are clipped.
    static func rectangle(x0: Int, y0: Int, x1: Int, y1: Int, width: Int, height: Int) -> SelectionMask {
        let mask = SelectionMask(width: width, height: height)
        let minX = max(0, min(x0, x1))
        let maxX = min(width - 1, max(x0, x1))
        let minY = max(0, min(y0, y1))
        let maxY = min(height - 1, max(y0, y1))
        guard minX <= maxX, minY <= maxY else { return mask }
        for y in minY...maxY {
            for x in minX...maxX {
                mask.setSelected(true, x: x, y: y)
            }
        }
        return mask
    }

    /// The side length of the per-pixel supersampling grid `antiAlias: true`
    /// uses below in `ellipse`/`polygon` (issue #56) — `4` (16 subsamples
    /// per pixel) is a standard, cheap-enough-for-pixel-art-canvas-sizes
    /// choice: enough gradation that a shallow diagonal edge doesn't look
    /// banded, without the cost of a much finer grid nothing here needs.
    private static let antiAliasSupersampleAxis = 4

    /// A filled ellipse selection. Each pixel's *center* — `(x + 0.5, y +
    /// 0.5)` — is tested against the ellipse equation
    /// `(dx/radiusX)^2 + (dy/radiusY)^2 <= 1`, not its corner, so a pixel is
    /// selected only when its center falls inside the ellipse.
    ///
    /// A non-positive `radiusX`/`radiusY` would make that equation divide by
    /// zero (or select nothing meaningful anyway — a zero-radius ellipse has
    /// no interior), so both are guarded and simply produce an empty mask.
    ///
    /// `antiAlias` (issue #56, default `false` — every pre-#56 call site
    /// keeps its exact single-center-sample behavior unmodified) instead
    /// tests a `4x4` grid of sub-pixel offsets per pixel and sets that
    /// pixel's coverage to the fraction that fell inside the ellipse — `0`
    /// and `4x4` (all outside/all inside) still collapse to `0`/`255`
    /// exactly like the non-antialiased path, so only pixels the ellipse's
    /// curved boundary actually crosses end up with an in-between value.
    /// Unlike `feathered(radius:)` (a post-process blur that can be applied
    /// to *any* mask, regardless of shape), this only softens the ellipse's
    /// own true geometric edge — it does not expand the selection outward
    /// the way feathering does.
    static func ellipse(centerX: Double, centerY: Double, radiusX: Double, radiusY: Double, width: Int, height: Int, antiAlias: Bool = false) -> SelectionMask {
        let mask = SelectionMask(width: width, height: height)
        guard radiusX > 0, radiusY > 0 else { return mask }
        let samplesPerAxis = antiAlias ? antiAliasSupersampleAxis : 1
        let sampleCount = samplesPerAxis * samplesPerAxis
        for y in 0..<height {
            for x in 0..<width {
                var insideCount = 0
                for sy in 0..<samplesPerAxis {
                    let dy = (Double(y) + (Double(sy) + 0.5) / Double(samplesPerAxis)) - centerY
                    for sx in 0..<samplesPerAxis {
                        let dx = (Double(x) + (Double(sx) + 0.5) / Double(samplesPerAxis)) - centerX
                        let normalized = (dx / radiusX) * (dx / radiusX) + (dy / radiusY) * (dy / radiusY)
                        if normalized <= 1 { insideCount += 1 }
                    }
                }
                guard insideCount > 0 else { continue }
                let value = insideCount == sampleCount ? UInt8(255) : UInt8((Double(insideCount) / Double(sampleCount) * 255).rounded())
                mask.setCoverage(value, x: x, y: y)
            }
        }
        return mask
    }

    /// A filled polygon selection, scan-converted from a free-form vertex
    /// path (issue #11, round 2: backs both the lasso's dragged path and the
    /// polygon tool's clicked-vertex path). The path is treated as
    /// implicitly closed — the last vertex is joined back to the first even
    /// if the caller never repeated it — matching how both tools describe
    /// "close the shape" (lasso: mouse-up; polygon: click near the first
    /// vertex or press Return).
    ///
    /// Each pixel's *center* — `(x + 0.5, y + 0.5)`, same convention as
    /// `ellipse(...)` — is tested against the polygon with the standard
    /// even-odd (crossing-number) rule: cast a ray from the pixel center
    /// toward `+x` and count how many polygon edges it crosses; odd means
    /// inside. This naturally handles self-intersecting/concave paths the
    /// same way Photoshop's lasso does, with no special-casing.
    ///
    /// Fewer than 3 vertices can't enclose any area, so that case is guarded
    /// and simply produces an empty mask (mirroring `ellipse(...)`'s
    /// non-positive-radius guard) rather than the degenerate 0- or 1-edge
    /// polygon that dropping straight into the ray-casting loop would trace.
    ///
    /// `antiAlias` (issue #56, default `false` — every pre-#56 call site
    /// keeps its exact single-center-sample behavior unmodified) supersamples
    /// each pixel the same `4x4`-grid way `ellipse(...)`'s own `antiAlias`
    /// does — see that parameter's doc comment for the general shape (only
    /// pixels the polygon's edges actually cross end up with in-between
    /// coverage; this backs both the lasso's free-form path and the polygon
    /// tool's clicked-vertex path, since both funnel through this one
    /// constructor).
    static func polygon(vertices: [(x: Int, y: Int)], width: Int, height: Int, antiAlias: Bool = false) -> SelectionMask {
        let mask = SelectionMask(width: width, height: height)
        guard vertices.count >= 3 else { return mask }

        func isInside(px: Double, py: Double) -> Bool {
            var inside = false
            var j = vertices.count - 1
            for i in 0..<vertices.count {
                let xi = Double(vertices[i].x) + 0.5
                let yi = Double(vertices[i].y) + 0.5
                let xj = Double(vertices[j].x) + 0.5
                let yj = Double(vertices[j].y) + 0.5
                // Standard even-odd crossing test: does edge (i, j)
                // straddle the horizontal line at `py`, and if so, does
                // it cross to the right of `px`?
                let straddles = (yi > py) != (yj > py)
                if straddles {
                    let crossingX = xi + (py - yi) / (yj - yi) * (xj - xi)
                    if px < crossingX {
                        inside.toggle()
                    }
                }
                j = i
            }
            return inside
        }

        let samplesPerAxis = antiAlias ? antiAliasSupersampleAxis : 1
        let sampleCount = samplesPerAxis * samplesPerAxis
        for y in 0..<height {
            for x in 0..<width {
                var insideCount = 0
                for sy in 0..<samplesPerAxis {
                    let py = Double(y) + (Double(sy) + 0.5) / Double(samplesPerAxis)
                    for sx in 0..<samplesPerAxis {
                        let px = Double(x) + (Double(sx) + 0.5) / Double(samplesPerAxis)
                        if isInside(px: px, py: py) { insideCount += 1 }
                    }
                }
                guard insideCount > 0 else { continue }
                let value = insideCount == sampleCount ? UInt8(255) : UInt8((Double(insideCount) / Double(sampleCount) * 255).rounded())
                mask.setCoverage(value, x: x, y: y)
            }
        }
        return mask
    }

    /// A selection of every pixel within `tolerance` of `(startX, startY)`'s
    /// own color, either flood-filled outward from that point (`contiguous:
    /// true`, the default) or scanned across the whole canvas regardless of
    /// connectivity (`contiguous: false`, issue #52) — Photoshop's own
    /// "Contiguous" option-bar checkbox for its magic wand tool.
    ///
    /// When `contiguous` grows outward through 4-connected neighbors (up/
    /// down/left/right only — no diagonals, unlike a typical paint-bucket's
    /// optional 8-connected mode, which is explicitly out of scope for this
    /// issue) so long as each candidate pixel's color is within `tolerance`
    /// of the *start* pixel's color — not its immediate neighbor's, matching
    /// how Photoshop's (non-"contiguous variance") magic wand samples a
    /// single reference color for the whole selection rather than letting
    /// small step-by-step drifts chain across a gradient.
    ///
    /// Color difference is the sum of the absolute per-channel differences
    /// across R, G, and B (a simple Manhattan/L1 distance — cheaper than a
    /// true Euclidean distance and plenty precise for a boolean "close
    /// enough" cutoff; alpha is deliberately excluded so a fully-opaque and
    /// a half-transparent pixel of the same RGB still count as the same
    /// color). `tolerance` is compared directly against that sum, so its
    /// useful range is roughly `0...(255 * 3)` — `0` matches only exact color
    /// equality with the start pixel.
    ///
    /// `colorAt` is a plain closure rather than a `PixelCanvas`/`LayerStack`
    /// parameter so this stays a pure, canvas-agnostic function like
    /// `rectangle`/`ellipse`/`polygon` above — easy to unit test without
    /// constructing a real canvas. It returns `nil` for any coordinate that
    /// has no color (e.g. out of bounds), which this method also uses as the
    /// flood-fill's own bounds check instead of comparing against
    /// `width`/`height` directly — one less place the two could disagree.
    ///
    /// If the start pixel itself has no color (`colorAt(startX, startY) ==
    /// nil`), this returns an empty mask rather than crashing or guessing a
    /// color to match against.
    ///
    /// `antiAlias` (issue #56, default `false`, matching every pre-#56 call
    /// site's exact hard-edged behavior) softens the flood-filled region's
    /// boundary. Unlike `ellipse`/`polygon`'s own `antiAlias`, the magic
    /// wand has no continuous shape to supersample — its selection is
    /// defined pixel-by-pixel by color similarity, not a geometric curve —
    /// so this is deliberately implemented as `feathered(radius:
    /// magicWandAntiAliasRadius)` applied to the finished boolean flood-fill
    /// result rather than a from-scratch supersampling pass: a small blur is
    /// the standard practical stand-in for "soften this boundary" when no
    /// sub-pixel geometry exists to sample against.
    static func magicWand(
        startX: Int, startY: Int,
        colorAt: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)?,
        tolerance: Int,
        width: Int, height: Int,
        contiguous: Bool = true,
        antiAlias: Bool = false
    ) -> SelectionMask {
        let mask = SelectionMask(width: width, height: height)
        guard let startColor = colorAt(startX, startY) else { return mask }

        func colorDistance(_ a: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Int {
            abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
        }

        // Non-contiguous mode (issue #52): no flood fill at all, just a
        // flat scan over every pixel on the canvas — connectivity to
        // `(startX, startY)` doesn't matter, only color similarity does, so
        // this skips `visited`/the stack entirely and returns early rather
        // than falling through into flood-fill machinery it wouldn't use.
        guard contiguous else {
            for y in 0..<height {
                for x in 0..<width {
                    guard let color = colorAt(x, y), colorDistance(color, startColor) <= tolerance else { continue }
                    mask.setSelected(true, x: x, y: y)
                }
            }
            return antiAlias ? mask.feathered(radius: magicWandAntiAliasRadius) : mask
        }

        var visited = Array(repeating: false, count: width * height)
        func markVisited(x: Int, y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            visited[y * width + x] = true
        }
        func isVisited(x: Int, y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return true }
            return visited[y * width + x]
        }

        // Stack-based (not recursive) flood fill so a large contiguous
        // region — e.g. an entire solid-color background on a big canvas —
        // can't overflow the call stack the way a naive recursive
        // implementation could.
        var stack: [(Int, Int)] = [(startX, startY)]
        markVisited(x: startX, y: startY)
        while let (x, y) = stack.popLast() {
            guard let color = colorAt(x, y), colorDistance(color, startColor) <= tolerance else { continue }
            mask.setSelected(true, x: x, y: y)
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx
                let ny = y + dy
                guard !isVisited(x: nx, y: ny) else { continue }
                markVisited(x: nx, y: ny)
                stack.append((nx, ny))
            }
        }
        return antiAlias ? mask.feathered(radius: magicWandAntiAliasRadius) : mask
    }

    /// The blur radius `magicWand`'s own `antiAlias` parameter feeds into
    /// `feathered(radius:)` (issue #56) — small enough to only soften the
    /// boundary by roughly a pixel (matching Photoshop's own magic-wand
    /// anti-alias, a subtle edge smoothing rather than a visible feather),
    /// not a general-purpose feather amount a caller can tune.
    private static let magicWandAntiAliasRadius: Double = 0.6

    // MARK: - Feathering

    /// Returns a new mask with this one's coverage blurred by `radius`
    /// pixels (issue #56) — Photoshop's "Feather" selection option. Unlike
    /// `ellipse`/`polygon`/`magicWand`'s own `antiAlias` (which only softens
    /// a shape's *own* true boundary, without changing which pixels are
    /// roughly in vs. out), feathering genuinely expands the soft region in
    /// both directions: pixels just outside the original hard edge gain some
    /// partial coverage, and pixels just inside it lose some — this can be
    /// applied to a mask built by *any* of the shape constructors (or a
    /// combined/inverted result), not just the two that take `antiAlias`.
    ///
    /// `radius <= 0` returns an unmodified copy — every existing hard-edged
    /// selection (feather 0, the default everywhere) is untouched byte for
    /// byte, matching this type's "existing boolean-mask callers keep their
    /// exact behavior" compatibility rule (see the type's own doc comment).
    ///
    /// `radius` is clamped to `maxRadius` (issue #56 independent review
    /// must-1) as a defensive backstop — see that constant's own doc
    /// comment for why, and `OptionBarView`'s Feather field for the primary,
    /// UI-level clamp a caller normally hits first.
    ///
    /// Implemented as three passes of a separable *box* blur (horizontal,
    /// then vertical, repeated three times), not a direct Gaussian
    /// convolution — three uniform-radius box blurs are a standard, widely
    /// used approximation of a true Gaussian (see e.g. Kovesi's "Fast
    /// Almost-Gaussian Filtering"), close enough for a selection's soft edge
    /// that no caller/test here can tell the difference. This is a
    /// deliberate replacement for an earlier direct-convolution
    /// implementation (issue #56 independent review must-1): that version's
    /// cost was `O(width * height * radius)` — a naive Gaussian kernel sized
    /// to `radius` re-summed at every pixel — which the reviewer measured
    /// hanging for 5+ minutes with no progress indicator or way to cancel at
    /// radius 200 on a mere 512x512 canvas (paintest allows canvases up to
    /// 4096x4096). Each box-blur pass here instead uses a *sliding-window*
    /// running sum (`boxBlurred1D(...)`) — add the pixel entering the
    /// window, remove the one leaving it — which costs `O(width * height)`
    /// per pass *regardless of the box's own radius*, so an arbitrarily
    /// large Feather value costs the same as a small one.
    ///
    /// Each box's radius is derived from `radius` (used as the Gaussian's
    /// notional sigma, same convention the direct-convolution version used)
    /// via the standard `d = sqrt(12·sigma²/n + 1)` box-diameter formula for
    /// `n` box-blur passes — here `n == 3`, this method's own pass count.
    ///
    /// A coordinate outside the canvas contributes `0` (unselected) to the
    /// blur, the same as it does everywhere else `SelectionMask` treats
    /// "outside the canvas" as "unselected" (see `contains(x:y:)`'s doc
    /// comment) — so feathering a selection that touches the canvas edge
    /// softens that edge too, rather than wrapping or clamping.
    func feathered(radius: Double) -> SelectionMask {
        guard radius > 0 else { return copy() }
        let sigma: Double = min(radius, Self.maxRadius)
        let sigmaSquared: Double = sigma * sigma
        let boxDiameterSquared: Double = 12.0 * sigmaSquared / 3.0 + 1.0
        let boxDiameter: Double = boxDiameterSquared.squareRoot()
        let roundedBoxRadius: Double = ((boxDiameter - 1.0) / 2.0).rounded()
        let boxRadius: Int = max(1, Int(roundedBoxRadius))

        var current = coverage.map { Double($0) / 255.0 }
        for _ in 0..<3 {
            current = Self.boxBlurred1D(current, lineLength: width, lineCount: height, radius: boxRadius, stride: 1, lineStride: width)
            current = Self.boxBlurred1D(current, lineLength: height, lineCount: width, radius: boxRadius, stride: width, lineStride: 1)
        }
        let result = current.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        return SelectionMask(width: width, height: height, coverage: result)
    }

    /// The largest Feather radius `feathered(radius:)` will actually use
    /// (issue #56 independent review must-1) — not a performance necessity
    /// any more (see `feathered(radius:)`'s own doc comment: the
    /// sliding-window box blur it now uses costs the same regardless of
    /// radius), but a sane UI-level ceiling all the same: a value far past
    /// this fully flattens any realistic selection's coverage to a uniform
    /// haze rather than a recognizable soft edge, so there's nothing a
    /// larger number would usefully express.
    static let maxRadius: Double = 100

    /// One box-blur pass over a flat buffer addressed as `lineCount` lines
    /// of `lineLength` samples each, generalizing "blur every row
    /// horizontally" and "blur every column vertically" into the same
    /// implementation (`stride`/`lineStride` pick which): `stride` is the
    /// distance between consecutive samples *within* a line (`1` for a row,
    /// `width` for a column), `lineStride` is the distance between the
    /// start of one line and the next (`width` for a row, `1` for a
    /// column).
    ///
    /// Uses a running sum that slides across each line — add the sample
    /// entering the `2 * radius + 1`-wide window, remove the one leaving it
    /// — rather than re-summing the whole window at every sample. That's
    /// what makes this `O(lineLength * lineCount)` total, independent of
    /// `radius` (see `feathered(radius:)`'s own doc comment for why that
    /// independence is the whole point). A sample position outside
    /// `0..<lineLength` contributes `0` to the window, matching
    /// `feathered(radius:)`'s "outside the canvas counts as unselected, no
    /// wrap/clamp" contract.
    private static func boxBlurred1D(_ source: [Double], lineLength: Int, lineCount: Int, radius: Int, stride: Int, lineStride: Int) -> [Double] {
        var result = [Double](repeating: 0, count: source.count)
        let windowSize = Double(radius * 2 + 1)
        for line in 0..<lineCount {
            let lineStart = line * lineStride
            var sum = 0.0
            for offset in -radius...radius where offset >= 0 && offset < lineLength {
                sum += source[lineStart + offset * stride]
            }
            for position in 0..<lineLength {
                result[lineStart + position * stride] = sum / windowSize
                let leaving = position - radius
                let entering = position + radius + 1
                if leaving >= 0, leaving < lineLength {
                    sum -= source[lineStart + leaving * stride]
                }
                if entering >= 0, entering < lineLength {
                    sum += source[lineStart + entering * stride]
                }
            }
        }
        return result
    }

    // MARK: - Combining
    //
    // All four assume `width`/`height` match between `self` and `other` —
    // callers only ever combine masks built for the same canvas (issue #11
    // scope). A mismatched `other` isn't guarded against: querying its
    // `contains(x:y:)` at an out-of-its-bounds coordinate just returns
    // `false` (see `contains(x:y:)`'s own doc comment), which at worst
    // silently under-selects rather than crashing — acceptable since this
    // is explicitly out of scope ("不一致は未定義でよい").

    /// Union — Shift's "add to selection". Combines coverage the standard
    /// fuzzy-logic way (issue #56: `max`, generalizing boolean OR) so two
    /// hard-edged (`0`/`255`-only) masks combine exactly as the old boolean
    /// `||` did, while a feathered/anti-aliased mask's in-between values
    /// still combine sensibly (the more-selected of the two coverages wins
    /// at each pixel).
    func unioned(with other: SelectionMask) -> SelectionMask {
        combined(with: other) { max($0, $1) }
    }

    /// Difference — Option's "subtract from selection". `min(a, 255 - b)`
    /// generalizes boolean `a && !b` the same fuzzy-logic way `unioned`
    /// generalizes `||` (issue #56).
    func subtracting(_ other: SelectionMask) -> SelectionMask {
        combined(with: other) { min($0, 255 - $1) }
    }

    /// Intersection — Shift+Option's "intersect with selection". `min`
    /// generalizes boolean `&&` the same fuzzy-logic way `unioned`
    /// generalizes `||` (issue #56).
    func intersected(with other: SelectionMask) -> SelectionMask {
        combined(with: other) { min($0, $1) }
    }

    private func combined(with other: SelectionMask, _ op: (UInt8, UInt8) -> UInt8) -> SelectionMask {
        var result = Array(repeating: UInt8(0), count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                result[y * width + x] = op(alpha(x: x, y: y), other.alpha(x: x, y: y))
            }
        }
        return SelectionMask(width: width, height: height, coverage: result)
    }

    /// The complement — every currently-unselected pixel becomes selected
    /// and vice versa. `255 - coverage` generalizes boolean negation the
    /// same fuzzy-logic way `unioned`/`subtracting`/`intersected` do (issue
    /// #56): a fully-selected pixel (`255`) becomes fully-unselected (`0`)
    /// and vice versa, and a feathered/anti-aliased pixel's partial coverage
    /// flips to its complement.
    func inverted() -> SelectionMask {
        SelectionMask(width: width, height: height, coverage: coverage.map { 255 - $0 })
    }

    // MARK: - Queries

    var isEmpty: Bool {
        !coverage.contains { $0 > 0 }
    }

    /// The smallest pixel-space rectangle (inclusive on all four sides)
    /// that encloses every selected pixel, or `nil` when the mask is
    /// entirely empty (mirroring `isEmpty` above rather than returning some
    /// degenerate zero-size rectangle for that case).
    ///
    /// Lets a caller that only cares about the mask's true extent — e.g.
    /// issue #38's bucket fill, which used to walk every pixel of the
    /// entire canvas just to find the (often much smaller) flood-filled
    /// region — scan only this rectangle instead of `0..<width` /
    /// `0..<height` unconditionally.
    var boundingBox: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where coverage[y * width + x] > 0 {
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return (minX, minY, maxX, maxY)
    }

    // MARK: - Outline tracing

    /// Every edge on the boundary between a selected pixel and an
    /// unselected (or out-of-bounds) neighbor, as pixel-space line segments
    /// (1 unit = 1 pixel; a selected pixel `(x, y)` occupies the unit square
    /// from `(x, y)` to `(x + 1, y + 1)`). `CanvasView` scales these by the
    /// current zoom before stroking them as a dashed "marching ants"-style
    /// outline.
    ///
    /// Deliberately shape-agnostic: this just walks every selected pixel and
    /// emits whichever of its 4 sides border a non-selected pixel, with no
    /// assumption about the mask being simply-connected, convex, or built
    /// from any particular shape. That naive per-pixel approach is what lets
    /// rounds 2/3's lasso/polygon/magic-wand selections reuse this method
    /// unchanged once their own masks exist.
    func boundaryEdges() -> [(NSPoint, NSPoint)] {
        var edges: [(NSPoint, NSPoint)] = []
        for y in 0..<height {
            for x in 0..<width {
                guard contains(x: x, y: y) else { continue }
                let left = NSPoint(x: x, y: y)
                let right = NSPoint(x: x + 1, y: y)
                let bottomLeft = NSPoint(x: x, y: y + 1)
                let bottomRight = NSPoint(x: x + 1, y: y + 1)

                if !contains(x: x, y: y - 1) {
                    edges.append((left, right))
                }
                if !contains(x: x, y: y + 1) {
                    edges.append((bottomLeft, bottomRight))
                }
                if !contains(x: x - 1, y: y) {
                    edges.append((left, bottomLeft))
                }
                if !contains(x: x + 1, y: y) {
                    edges.append((right, bottomRight))
                }
            }
        }
        return edges
    }
}
