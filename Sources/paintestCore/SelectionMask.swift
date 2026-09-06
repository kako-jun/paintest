import AppKit

/// A pixel-space selection region — the set of pixels currently eligible for
/// editing (issue #11: "柔軟な範囲選択"). Kept as a plain, feather-free
/// boolean mask rather than a path or a float alpha mask, matching
/// `PixelCanvas`'s "dot-exact, no blur" philosophy: a pixel is either inside
/// the selection or it isn't, with no soft edges.
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

    /// Row-major, `width * height` booleans — `cells[y * width + x]` is
    /// whether pixel `(x, y)` is selected. A flat array (not `PixelCanvas`'s
    /// raw byte buffer) is enough here: nothing about this type needs to be
    /// an `NSBitmapImageRep` or round-trip through PNG.
    private var cells: [Bool]

    /// Starts with nothing selected.
    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.cells = Array(repeating: false, count: self.width * self.height)
    }

    private init(width: Int, height: Int, cells: [Bool]) {
        self.width = width
        self.height = height
        self.cells = cells
    }

    private func index(x: Int, y: Int) -> Int? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return y * width + x
    }

    /// Whether pixel `(x, y)` is selected. Always `false` for a coordinate
    /// outside the mask's bounds — never a bounds error — so callers (e.g.
    /// `PixelCanvas`'s paint guards) can query it unconditionally.
    func contains(x: Int, y: Int) -> Bool {
        guard let i = index(x: x, y: y) else { return false }
        return cells[i]
    }

    /// Sets whether pixel `(x, y)` is selected. Silently ignored for a
    /// coordinate outside the mask's bounds.
    func setSelected(_ selected: Bool, x: Int, y: Int) {
        guard let i = index(x: x, y: y) else { return }
        cells[i] = selected
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

    /// A filled ellipse selection. Each pixel's *center* — `(x + 0.5, y +
    /// 0.5)` — is tested against the ellipse equation
    /// `(dx/radiusX)^2 + (dy/radiusY)^2 <= 1`, not its corner, so a pixel is
    /// selected only when its center falls inside the ellipse.
    ///
    /// A non-positive `radiusX`/`radiusY` would make that equation divide by
    /// zero (or select nothing meaningful anyway — a zero-radius ellipse has
    /// no interior), so both are guarded and simply produce an empty mask.
    static func ellipse(centerX: Double, centerY: Double, radiusX: Double, radiusY: Double, width: Int, height: Int) -> SelectionMask {
        let mask = SelectionMask(width: width, height: height)
        guard radiusX > 0, radiusY > 0 else { return mask }
        for y in 0..<height {
            let dy = (Double(y) + 0.5) - centerY
            for x in 0..<width {
                let dx = (Double(x) + 0.5) - centerX
                let normalized = (dx / radiusX) * (dx / radiusX) + (dy / radiusY) * (dy / radiusY)
                if normalized <= 1 {
                    mask.setSelected(true, x: x, y: y)
                }
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
    static func polygon(vertices: [(x: Int, y: Int)], width: Int, height: Int) -> SelectionMask {
        let mask = SelectionMask(width: width, height: height)
        guard vertices.count >= 3 else { return mask }

        for y in 0..<height {
            let py = Double(y) + 0.5
            for x in 0..<width {
                let px = Double(x) + 0.5
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
                if inside {
                    mask.setSelected(true, x: x, y: y)
                }
            }
        }
        return mask
    }

    /// A flood-filled selection starting at `(startX, startY)` (issue #11,
    /// round 3 of 3: the magic wand). Grows outward through 4-connected
    /// neighbors (up/down/left/right only — no diagonals, unlike a typical
    /// paint-bucket's optional 8-connected mode, which is explicitly out of
    /// scope for this issue) so long as each candidate pixel's color is
    /// within `tolerance` of the *start* pixel's color — not its immediate
    /// neighbor's, matching how Photoshop's (non-"contiguous variance")
    /// magic wand samples a single reference color for the whole selection
    /// rather than letting small step-by-step drifts chain across a gradient.
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
    static func magicWand(
        startX: Int, startY: Int,
        colorAt: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)?,
        tolerance: Int,
        width: Int, height: Int
    ) -> SelectionMask {
        let mask = SelectionMask(width: width, height: height)
        guard let startColor = colorAt(startX, startY) else { return mask }

        func colorDistance(_ a: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Int {
            abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
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
        return mask
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

    /// Union — Shift's "add to selection".
    func unioned(with other: SelectionMask) -> SelectionMask {
        combined(with: other) { $0 || $1 }
    }

    /// Difference — Option's "subtract from selection".
    func subtracting(_ other: SelectionMask) -> SelectionMask {
        combined(with: other) { $0 && !$1 }
    }

    /// Intersection — Shift+Option's "intersect with selection".
    func intersected(with other: SelectionMask) -> SelectionMask {
        combined(with: other) { $0 && $1 }
    }

    private func combined(with other: SelectionMask, _ op: (Bool, Bool) -> Bool) -> SelectionMask {
        var result = Array(repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                result[y * width + x] = op(contains(x: x, y: y), other.contains(x: x, y: y))
            }
        }
        return SelectionMask(width: width, height: height, cells: result)
    }

    /// The complement — every currently-unselected pixel becomes selected
    /// and vice versa.
    func inverted() -> SelectionMask {
        SelectionMask(width: width, height: height, cells: cells.map { !$0 })
    }

    // MARK: - Queries

    var isEmpty: Bool {
        !cells.contains(true)
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
