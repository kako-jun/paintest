import AppKit

/// A pixel-space selection region — the set of pixels currently eligible for
/// editing (issue #11: "柔軟な範囲選択"). Kept as a plain, feather-free
/// boolean mask rather than a path or a float alpha mask, matching
/// `PixelCanvas`'s "dot-exact, no blur" philosophy: a pixel is either inside
/// the selection or it isn't, with no soft edges.
///
/// This round (round 1 of 3) only needs to build masks from rectangle and
/// ellipse marquees (`rectangle(...)`/`ellipse(...)`), combine them
/// (`unioned`/`subtracting`/`intersected`), and trace their outline
/// (`boundaryEdges()`). Lasso/polygon/magic-wand selections (rounds 2-3) are
/// expected to build a `SelectionMask` some other way (e.g. scan-converting
/// a free-form path, or flood-filling) but then reuse every method here
/// unchanged — `boundaryEdges()` in particular is deliberately shape-agnostic
/// (see its own doc comment) so it doesn't need revisiting once those land.
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
